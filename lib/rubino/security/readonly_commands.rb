# frozen_string_literal: true

require "shellwords"

module Rubino
  module Security
    # Built-in auto-allow layer for provably READ-ONLY shell commands.
    #
    # Sits at the same decision step as the user command allowlist
    # (ApprovalPolicy step 6) — BELOW the hardline floor and permissions:deny,
    # which always run first, and ABOVE the confirm-policy prompt. A command
    # auto-allows ONLY when the ENTIRE line parses as safe:
    #
    #   - every chain segment (split on |, &&, ||, ;, newline) starts with a
    #     command from the read-only set (or approvals.readonly_commands);
    #   - no output redirection (>, >>, 2>; `tee` is simply not in the set),
    #     no command substitution ($(...) or backticks, live contexts only —
    #     single-quoted text is literal and stays allowed), no process
    #     substitution (<(...), >(...)), no backgrounding (&);
    #   - no leading variable assignments (FOO=bar cmd → prompt);
    #   - no mutating flags on otherwise-safe heads (find -exec/-delete/...,
    #     date -s, tree -o, git --output);
    #   - git only with a read-only subcommand, conservatively flag-checked;
    #   - no DangerousPatterns match on the whole line (defense-in-depth for
    #     user-extended sets).
    #
    # Anything the scanner cannot prove safe FAILS CLOSED to the normal
    # approval prompt — never to silent execution. Pure functions, no I/O.
    module ReadonlyCommands
      # Read-only command heads auto-allowed by default. Conservative: each
      # entry must be side-effect-free for ANY argument list once the flag
      # checks below pass. `git` is handled separately (per-subcommand).
      SAFE_COMMANDS = %w[
        ls pwd find cat head tail grep rg wc file stat du df which
        whoami date tree echo
      ].freeze

      # git subcommands that never mutate the repository. `remote` is
      # restricted further below (bare or -v only — `git remote add` mutates),
      # `branch` to pure-flag listing forms (`git branch foo` CREATES a branch).
      GIT_READONLY_SUBCOMMANDS = %w[status log diff show rev-parse blame].freeze

      # Exec-capable git option FLAGS that, on ANY git command (including an
      # otherwise read-only subcommand like `diff`/`log`), turn the invocation
      # into arbitrary command execution by activating a repo-config driver.
      # These run a `diff.<n>.command` / textconv program straight from the
      # repository config WITHOUT any approval (#536: `git diff --ext-diff`
      # live-created /tmp/PWNED via a poisoned diff driver). A read-only intent
      # never needs them, so their presence disqualifies the auto-allow and the
      # allowlist fast-path — the command still runs, but only AFTER approval.
      # Matched as an exact token (and `flag=value` form, e.g. `--textconv=cmd`).
      GIT_EXEC_OPTION_FLAGS = %w[
        --ext-diff --textconv -c --config-env --exec-path
        --git-dir --work-tree --namespace --attr-source -C
        --upload-pack --receive-pack -u
      ].freeze

      # Config KEYS (used as the value of `-c key=val` / `--config-env key=env`,
      # or anywhere a config name can appear) whose value git executes as a
      # command: a poisoned one is RCE. Matched case-insensitively against any
      # token via a substring scan so `-cdiff.external=…` (glued), `--config-env
      # diff.external=…` and a bare `diff.external` all trip. `*` stands for the
      # arbitrary middle segment of `diff.<n>.command`.
      GIT_EXEC_CONFIG_KEYS = %w[
        diff.external core.pager core.sshcommand core.fsmonitor
        core.hookspath core.editor sequence.editor uploadpack.packobjectshook
        gpg.program ssh.variant
      ].freeze
      # Config-key patterns with a wildcard middle segment (per-name drivers).
      GIT_EXEC_CONFIG_KEY_PATTERNS = [
        /\bdiff\.[^=\s]+\.command\b/i,
        /\bdiff\.[^=\s]+\.textconv\b/i,
        /\bfilter\.[^=\s]+\.(?:clean|smudge|process)\b/i
      ].freeze
      GIT_BRANCH_READONLY_FLAGS = %w[
        -a -r -v -vv --list --all --remotes --show-current --verbose
        --merged --no-merged --color --no-color
      ].freeze

      # Mutating/executing flags that disqualify an otherwise-safe head.
      # Matched as exact token or `flag=value`. Heads that read by default but
      # gain a WRITE or an EXEC through one of these flags: an allowlisted entry
      # for the head pre-approves the read, never the smuggled write/exec.
      #   sort -o FILE / --output=FILE         arbitrary write (SEC-R2-2)
      # (sed/tar/tee/awk/... are handled by CODE_EXEC_HEADS below — their
      # argument is itself a program / they pipe to a shell, so no flag list can
      # make an arbitrary-arg invocation safe.)
      FORBIDDEN_FLAGS = {
        "find" => %w[-exec -execdir -ok -okdir -delete -fprintf -fprint -fprint0 -fls],
        "date" => %w[-s --set],
        "tree" => %w[-o],
        "sort" => %w[-o --output]
      }.freeze

      # Heads whose very PURPOSE is to run arbitrary code (or whose argument is
      # a program that can spawn a shell), so no flag inspection can make an
      # arbitrary-arg invocation provably safe. An allowlist entry for one of
      # these is DENIED auto-approval outright (default-deny): being on the
      # allowlist must never pre-approve `awk 'BEGIN{system("…")}'`,
      # `sed -n '…e cmd'`, `perl -e …`, `tee FILE`, etc. (SEC-R2-2). This is the
      # convenience-layer floor; these still run after an explicit prompt.
      CODE_EXEC_HEADS = %w[
        awk gawk mawk sed perl python python2 python3 ruby node php pwsh
        bash sh zsh ksh dash env xargs eval source tee tar dd
      ].freeze

      # Leading `FOO=bar cmd` environment assignment — rejected, not stripped:
      # an assignment can change what the command resolves to (PATH=...) or
      # how it behaves, so it is never "provably read-only".
      ASSIGNMENT_RE = /\A[A-Za-z_][A-Za-z0-9_]*=/

      module_function

      # True when the ENTIRE command line is provably read-only. `extra` is
      # the approvals.readonly_commands config: command names or leading-token
      # prefixes ("jq", "docker ps") merged into the built-in set.
      def auto_allowed?(command, extra: [])
        return false if DangerousPatterns.dangerous?(command)

        segments = split_segments(command.to_s)
        return false if segments.nil? || segments.empty?

        segments.all? { |segment| safe_segment?(segment, extra: extra) }
      end

      # Splits a command line into chain segments (|, ||, &&, ;, newline),
      # quote-aware. Returns nil — reject — on any construct that could smuggle
      # a write or an execution: a file-writing redirection (`> file`, `>> log`,
      # `2> err.txt`), backgrounding (&), command substitution ($( or backtick
      # in a live context), process substitution (<( / >( )), comments, trailing
      # backslash, unterminated quotes. Plain `<` input redirection stays
      # allowed. NON-WRITE redirects (fd-dup `2>&1`, discard-to-`/dev/null`) are
      # consumed and DROPPED so a read-only command carrying them still
      # auto-allows (#68) — the model habitually appends `2>&1`/`>/dev/null`.
      # Single-quoted text is literal in POSIX shells, so substitutions inside it
      # are safe to keep.
      def split_segments(command)
        segments = []
        current = +""
        i = 0
        while i < command.length
          char = command[i]
          succ = command[i + 1]
          case char
          when "'", "\""
            quoted = consume_quoted(command, i, char)
            return nil unless quoted

            current << quoted
            i += quoted.length
            next
          when "\\"
            return nil if succ.nil?

            current << char << succ
            i += 1
          when "`", "#"
            return nil
          when ">", "&", ";", "\n", "|"
            # A NON-WRITE redirect (`2>&1`, `>/dev/null`, `&>/dev/null`) is
            # dropped (segment kept); a chain operator (`;`/`\n`/`|`/`&&`) flushes
            # the segment; a write-to-file redirect or lone `&` rejects.
            redir = consume_redirect(command, i)
            return nil if redir == :reject

            unless redir # not a redirect → chain boundary
              redir = flush_segment(char, succ, segments, current) or return nil
              current = +""
            end
            i += redir
            next
          when "$", "<"
            return nil if succ == "("

            current << char
          else
            current << char
          end
          i += 1
        end
        segments << current
        segments.map(&:strip).reject(&:empty?)
      end

      # Resolves a redirect at +at+ (`>` or `&>`): returns the char count to skip
      # for a NON-WRITE redirect (`2>&1`, `>/dev/null`, `&>/dev/null`), :reject
      # for a write-to-file redirect, or nil when there is NO redirect here (a
      # chain operator the caller flushes instead).
      def consume_redirect(command, at)
        redir = at                       # index of the `>`
        redir += 1 if command[at] == "&" # `&>` redirects both streams
        return nil unless command[redir] == ">"

        consumed = consume_safe_redirect(command, redir)
        return :reject unless consumed

        consumed + (redir - at)
      end

      # The redirect targets that perform NO arbitrary-file write: an fd
      # duplication (`>&1`, `>&2`) or a discard to the null device
      # (`>/dev/null`). Anything else (`> out.txt`, `>> log`) writes a file and
      # is rejected. Returns the number of chars consumed from `start` (the `>`),
      # or nil to reject. `start` points at the FIRST `>` of the operator (a
      # preceding fd digit like the `2` in `2>&1` is already in `current`, which
      # is harmless — a bare `2` head fails the safe-command check anyway, and a
      # real read-only head sits before it).
      def consume_safe_redirect(command, start)
        # Skip the `>` (and a second `>` for the `>>` append form).
        i = start + 1
        i += 1 if command[i] == ">"
        rest = command[i..] || ""

        # fd duplication: `>&1`, `>&2`, `>&-`.
        return (i - start) + 2 if rest =~ /\A&[0-9-]/

        # Discard to the null device: `>/dev/null` (optionally with leading
        # whitespace, e.g. `> /dev/null`). The path must be EXACTLY /dev/null —
        # anchored so `/dev/nullx` (an arbitrary file) is NOT treated as the
        # device. A following redirect/chain/whitespace/EOL ends the token.
        m = rest.match(%r{\A\s*/dev/null(?=[\s;&|>]|\z)})
        return (i - start) + m.end(0) if m

        nil # writes an arbitrary file → reject
      end

      # Flushes the segment ended by a chain operator and returns how many
      # characters the operator consumes (2 for && and ||, 1 otherwise), or
      # nil for a lone & — backgrounding is never provably read-only.
      def flush_segment(char, succ, segments, current)
        return nil if char == "&" && succ != "&"

        segments << current
        "|&".include?(char) && succ == char ? 2 : 1
      end

      # Consumes the quoted region opening at `start`. Returns the full
      # substring including both quotes, or nil when the quote is unterminated
      # or — for double quotes, where substitutions stay LIVE — when it
      # contains $( or a backtick. Single-quoted text is literal in POSIX
      # shells, so anything inside is safe to keep verbatim.
      def consume_quoted(command, start, quote)
        i = start + 1
        while i < command.length
          char = command[i]
          if quote == "\""
            return nil if char == "`" || (char == "$" && command[i + 1] == "(")

            if char == "\\"
              i += 2
              next
            end
          end
          return command[start..i] if char == quote

          i += 1
        end
        nil
      end

      # One pipeline segment: tokenize (Shellwords — a parse error rejects),
      # refuse leading assignments, then require the head to be a safe command
      # whose flags pass the per-command checks, or an `extra` config entry.
      def safe_segment?(segment, extra: [])
        tokens = Shellwords.split(segment)
        return false if tokens.empty? || tokens.first.match?(ASSIGNMENT_RE)

        head = tokens.first
        return safe_git?(tokens) if head == "git"
        return safe_flags?(head, tokens) if SAFE_COMMANDS.include?(head)

        extra_match?(tokens, extra)
      rescue ArgumentError
        false # unbalanced quotes etc. — fall through to the prompt
      end

      def safe_flags?(head, tokens)
        forbidden = FORBIDDEN_FLAGS[head]
        return true unless forbidden

        tokens.drop(1).none? do |token|
          forbidden.any? { |flag| token == flag || token.start_with?("#{flag}=") }
        end
      end

      # Heads that are otherwise allowlistable but can still WRITE or EXEC
      # through trailing flags (git --output, find -exec/-delete/-fprintf,
      # date -s, tree -o, sort -o, tar --to-command). The user command allowlist
      # reuses this to vet the flags of a matched entry, so an allowlisted head
      # (e.g. `git diff`) can never smuggle an arbitrary write via `--output`.
      FLAG_VETTED_HEADS = (["git"] + FORBIDDEN_FLAGS.keys).freeze

      # True when `tokens` (a single already-split, non-chained segment whose
      # head matched a user allowlist entry) must NOT be auto-approved because
      # the head can WRITE or EXEC arbitrary code with these arguments. An
      # allowlist entry pre-approves the EXACT read-only intent of a head, never
      # a smuggled write/exec form. Pure inspection; it does NOT require the
      # command to be read-only overall (an allowlist entry is user-chosen), it
      # only rejects the forms that turn a read into a write/exec.
      #
      #   - CODE_EXEC_HEADS (awk/sed/perl/python/tar/tee/xargs/...) are
      #     default-denied outright: their argument IS a program (or pipes to a
      #     shell), so `awk 'BEGIN{system("…")}'`, `sed -e '…'`, `tar
      #     --to-command=sh` can't be made provably safe by flag inspection
      #     (SEC-R2-2);
      #   - git is screened for BOTH global flags before the subcommand
      #     (`-c alias.X=!cmd`, `-c core.sshCommand=…`, `-C dir`, `--exec-path`)
      #     and a code-loading/writing subcommand (`apply`, `am`, hooks, …) and
      #     the --output/-o write flag (SEC-R2-1);
      #   - the remaining FORBIDDEN_FLAGS heads (find/date/tree/sort/...) are
      #     screened for their specific write/exec flags.
      def dangerous_flags?(tokens)
        head = tokens.first
        return true if CODE_EXEC_HEADS.include?(head)
        return false unless FLAG_VETTED_HEADS.include?(head)

        if head == "git"
          dangerous_git?(tokens)
        else
          !safe_flags?(head, tokens)
        end
      end

      # Heads that load/run a SCRIPT FILE by default (a coding agent runs these
      # constantly — `python test.py`, `node build.js`, `bash script.sh`). The
      # bare file-arg form is SAFE; only specific inline-code/eval/exec/write
      # flags below turn them into arbitrary code (dangerous_flag_form?).
      #   - `-c <code>`           python/bash/sh/zsh/ksh/dash run inline source
      #   - `-e` / `-E` / `--eval` ALONE  perl/ruby/node bare-eval program
      #     (NOT `-pe`/`-ne`/`-pE`/`-nE` — those are stream READ filters, kept
      #     ALLOW: the danger is arbitrary code, not a line-by-line filter).
      INLINE_CODE_FLAGS = %w[-c -e -E --eval --exec].freeze
      # `-pe`/`-ne`/`-pE`/`-nE` perl/ruby filters: the `-e` rides a read mode, so
      # the invocation is a stream filter, not a bare eval. Kept ALLOW.
      INLINE_CODE_FILTER_FLAGS = %w[-pe -ne -pE -nE -ape -nle].freeze

      # The NARROW dangerous-flag-form screen used by the DEFAULT confirm gate
      # (dangerous_only). UNLIKE the broad #dangerous_flags? (which rejects every
      # CODE_EXEC_HEAD by its head, so even a bare `python test.py` / `sed
      # 's/a/b/'` trips), this prompts ONLY for the genuinely dangerous WRITE/EXEC
      # FLAG-FORMS and leaves ordinary script/filter invocations to auto-run.
      # True ONLY for:
      #   (a) git exec/config flag-forms (`-c`, `--config-env`, `--ext-diff`,
      #       `diff.external=…`, …) — reuse git_exec_vector?;
      #   (b) git `--output`/`-o` (a write) — reuse git_write_flag?;
      #   (c) FORBIDDEN_FLAGS heads carrying their write/exec flag (find
      #       -exec/-delete, sort -o/--output, date -s, tree -o);
      #   (d) a CODE_EXEC_HEAD carrying an inline-code/eval/exec/write flag:
      #       `-c` (python/bash/sh/…), a lone `-e`/`-E`/`--eval` (perl/ruby/node),
      #       `sed -i`/`--in-place`, `tar --to-command`/`-O`, `tee` (always
      #       writes), `dd of=…`, `xargs`/`env`/`eval` running another command.
      # A CODE_EXEC_HEAD with ONLY a script/file arg, or a `-pe`/`-ne` read
      # filter, is NOT flagged. A bare interpreter is NOT flagged. `tokens` is one
      # already-split, non-chained segment.
      def dangerous_flag_form?(tokens)
        return false if tokens.empty?

        head = tokens.first
        return dangerous_git?(tokens) if head == "git"
        return !safe_flags?(head, tokens) if FORBIDDEN_FLAGS.key?(head)
        return dangerous_code_exec_form?(head, tokens) if CODE_EXEC_HEADS.include?(head)

        false
      end

      # The EXEC/network/system SUBSET of #dangerous_flag_form? — the forms that
      # still warrant a prompt EVEN WHEN the OS write-jail is ACTIVE (slice 2
      # Part C). The jail confines arbitrary WRITES, so the pure-write flag-forms
      # (`sort -o`, `tree -o`, `find -delete`, `git --output`, `sed -i`, `dd of=`,
      # `tee`, `tar` write/extract) no longer need a prompt once it is enforcing.
      # But these still RUN ARBITRARY CODE (network exfil, reading secrets) or
      # mutate the SYSTEM beyond the file jail, so the prompt stays a speed bump:
      #   (a) git EXEC vectors (`-c`, `--config-env`, `--ext-diff`, `--textconv`,
      #       `core.sshCommand`, …) and the EXEC/NETWORK git subcommands
      #       (apply/am/hooks run attacker code; push/pull/fetch/clone/send-email
      #       touch the network) — git --output ALONE (a pure write) does NOT
      #       trip this;
      #   (b) FORBIDDEN_FLAGS EXEC forms only: `find -exec`/`-execdir`/`-ok`/
      #       `-okdir` (run a program) and `date -s` (mutate the system clock).
      #       `find -delete`/`-fprintf`/… and `sort -o`/`tree -o` (pure writes)
      #       do NOT trip this;
      #   (c) a CODE_EXEC_HEAD carrying an INLINE-CODE/EVAL/EXEC flag
      #       (`python -c`, `bash -c`, `perl -e`, `--eval`, `tar --to-command`,
      #       `xargs/env/eval CMD`) — `sed -i`/`tee`/`dd of=` (pure writes) do
      #       NOT trip this.
      # Conservative split: when in doubt a form is treated as EXEC (keeps
      # prompting). `tokens` is one already-split, non-chained segment.
      def exec_flag_form?(tokens)
        return false if tokens.empty?

        head = tokens.first
        return git_exec_vector?(tokens) || dangerous_git_exec_subcommand?(tokens) if head == "git"
        return find_or_date_exec_form?(head, tokens) if FORBIDDEN_FLAGS.key?(head)
        return code_exec_eval_form?(head, tokens) if CODE_EXEC_HEADS.include?(head)

        false
      end

      # The EXEC subset of FORBIDDEN_FLAGS: find's program-running flags and
      # `date -s` (system-clock mutation). find's pure-write flags (`-delete`,
      # `-fprintf`, `-fprint`, `-fprint0`, `-fls`) and `sort -o`/`tree -o` are
      # jail-contained writes and are NOT included.
      FIND_EXEC_FLAGS = %w[-exec -execdir -ok -okdir].freeze
      def find_or_date_exec_form?(head, tokens)
        args = tokens.drop(1)
        case head
        when "find" then args.any? { |t| FIND_EXEC_FLAGS.include?(t) }
        when "date" then args.any? { |t| t == "-s" || t == "--set" || t.start_with?("--set=") }
        else false
        end
      end

      # The EXEC subset of #dangerous_code_exec_form?: inline-code/eval/exec
      # forms that RUN arbitrary code. The pure-write forms (`tee`, `sed -i`,
      # `dd of=`) are dropped — the jail contains their writes. `tar
      # --to-command`/`-O` pipe to a shell (exec) so they stay.
      def code_exec_eval_form?(head, tokens)
        args = tokens.drop(1)
        return true if head == "tar" && args.any? { |t| tar_exec_flag?(t) }
        return true if %w[xargs env eval].include?(head) && args.any? { |t| !t.start_with?("-") }

        args.any? { |t| inline_code_flag?(t) }
      end

      # The EXEC/network git subcommands (run attacker code or touch the
      # network), as opposed to the pure-write `--output` flag-form. Reuses the
      # global-flag skipping of #dangerous_git? to find the subcommand token.
      GIT_EXEC_SUBCOMMANDS = %w[
        apply am rebase merge cherry-pick revert checkout switch restore
        stash push pull fetch clone hook filter-branch send-email daemon
      ].freeze
      def dangerous_git_exec_subcommand?(tokens)
        rest = tokens.drop(1)
        i = 0
        while i < rest.length
          tok = rest[i]
          break unless tok.start_with?("-")

          i += 1 if %w[-c -C].include?(tok) && !rest[i + 1].nil?
          i += 1
        end
        sub = rest[i]
        !sub.nil? && GIT_EXEC_SUBCOMMANDS.include?(sub)
      end

      # True when a CODE_EXEC_HEAD invocation carries an inline-code/eval/exec/
      # write flag (vs. running a plain script/file). Heads that ALWAYS write or
      # pipe to a shell (`tee`, `tar --to-command`, `dd of=`) are flagged on the
      # head/operand; the rest need an explicit inline-code/eval flag.
      def dangerous_code_exec_form?(head, tokens)
        return true if head == "tee" # tee ALWAYS writes its operand

        args = tokens.drop(1)
        return true if head == "tar" && args.any? { |t| tar_exec_flag?(t) }
        return true if head == "dd"  && args.any? { |t| t.start_with?("of=") }
        return true if %w[xargs env eval].include?(head) && args.any? { |t| !t.start_with?("-") }

        args.any? { |t| inline_code_flag?(t) } || sed_in_place?(head, args)
      end

      # `tar --to-command=PROG` pipes each member to a shell command, and `-O`
      # extracts to stdout (used to pipe into a shell): both EXEC vectors.
      def tar_exec_flag?(token)
        token == "--to-command" || token.start_with?("--to-command=") || token == "-O"
      end

      # An inline-code/eval/exec flag (`-c`, lone `-e`/`-E`/`--eval`, `--exec`),
      # excluding the `-pe`/`-ne` read-filter forms which stay ALLOW.
      def inline_code_flag?(token)
        return false if INLINE_CODE_FILTER_FLAGS.include?(token)

        INLINE_CODE_FLAGS.include?(token)
      end

      # `sed -i` / `sed --in-place` (and the glued backup form `-i.bak`) edits
      # the file in place — a write, so it is flagged.
      def sed_in_place?(head, args)
        return false unless head == "sed"

        args.any? { |t| t == "-i" || t.start_with?("-i.") || t == "--in-place" || t.start_with?("--in-place=") }
      end

      # Git GLOBAL flags (between `git` and the subcommand) that load or run
      # arbitrary code, and the dangerous subcommands an allowlisted bare `git`
      # would otherwise pre-approve. None of these belong to a read-only git
      # intent, so an allowlisted git head carrying any of them is rejected.
      #
      #   -c <name>=<val> / -c<name>=<val>   sets config for this invocation; the
      #     load-bearing ones are alias.* (a `!cmd` alias = RCE), core.sshCommand,
      #     core.pager, core.editor, core.hooksPath, core.fsmonitor,
      #     uploadpack/receivepack.* — all run a command. We reject -c entirely
      #     for an auto-approved git: a read-only git never needs per-call config.
      #   --config-env=<name>=<envvar>       sets config like -c, sourcing the
      #     VALUE from an environment variable (so `--config-env=alias.x=PWNVAR`
      #     with PWNVAR='!cmd' is the same RCE as `-c alias.x='!cmd'`). Rejected
      #     for the same reason as -c (SEC-R3-1).
      #   --attr-source=<tree>               reads .gitattributes from an
      #     arbitrary tree-ish; not config, but never part of a read-only intent,
      #     so rejected too (SEC-R3-1).
      #   -C <path> / --exec-path[=path]     changes the working dir / git's exec
      #     path (which can point git at attacker binaries).
      GIT_GLOBAL_EXEC_FLAGS = %w[
        -c --config-env --exec-path --git-dir --work-tree --namespace --attr-source -C
      ].freeze

      # Subcommands that mutate the working tree / apply attacker-supplied data /
      # run hooks, never part of a read-only intent. An allowlisted git head must
      # not pre-approve them even though they don't start with `-`.
      GIT_DANGEROUS_SUBCOMMANDS = %w[
        apply am rebase merge cherry-pick revert reset checkout switch restore
        clean stash push pull fetch clone commit hook filter-branch
        update-index update-ref symbolic-ref config send-email daemon
      ].freeze

      # True when a git invocation whose head matched an allowlist entry carries
      # a code-loading global flag, a dangerous subcommand, or an output-writing
      # flag. Scans the GLOBAL flag region (before the subcommand) AND the rest.
      def dangerous_git?(tokens)
        # Exec-capable vectors (--ext-diff/--textconv/-c diff.external/…) are
        # dangerous wherever they appear — screen the whole line first (#536).
        return true if git_exec_vector?(tokens)

        rest = tokens.drop(1)
        # Global flag region: everything up to the first non-flag token (the
        # subcommand). `-c name=val` / `-C path` may consume the next token as
        # their value, so a value that happens to look like a subcommand isn't
        # mistaken for one.
        i = 0
        while i < rest.length
          tok = rest[i]
          break unless tok.start_with?("-")

          return true if git_global_exec_flag?(tok)

          # -c / -C / --exec-path take a value as the NEXT token when not glued.
          i += 1 if %w[-c -C].include?(tok) && !rest[i + 1].nil?
          i += 1
        end

        sub = rest[i]
        return true if sub && GIT_DANGEROUS_SUBCOMMANDS.include?(sub)

        git_write_flag?(rest.drop(i + 1))
      end

      # A global-flag token matches when it is the exact flag (`-c`,
      # `--exec-path`), its `flag=value` form (`--exec-path=/x`), or a glued
      # short form (`-cNAME=VAL`, `-Cpath`).
      def git_global_exec_flag?(tok)
        GIT_GLOBAL_EXEC_FLAGS.any? do |f|
          tok == f ||
            tok.start_with?("#{f}=") ||
            (f.length == 2 && f.start_with?("-") && !f.start_with?("--") && tok.start_with?(f) && tok.length > 2)
        end
      end

      # Git flags that write the output to an arbitrary file:
      #   --output <file> / --output=<file>  (git diff/log/show/format-patch)
      #   -o <file> / -o<file>               (short form, git log/format-patch)
      # `-O<orderfile>` reads an orderfile (no write) but is rejected too, so a
      # short-flag write form can never slip through ambiguity. Matched on the
      # whole rest of the segment (token or `flag=value` / glued `-oFILE`).
      def git_write_flag?(rest)
        rest.any? do |t|
          t == "--output" || t.start_with?("--output=", "-o", "-O")
        end
      end

      # True when ANY token in a git invocation is an exec-capable vector: a
      # config-override flag (`-c`/`--config-env`), an external-driver flag
      # (`--ext-diff`/`--textconv`), a workspace/exec-path redirect, or a token
      # naming a command-executing config key (`diff.external`, `core.pager`,
      # `diff.<n>.command`, `filter.<n>.clean`, …). This is the Codex-model
      # structural screen: a read-only git NEVER carries any of these, so their
      # presence — anywhere in the line — disqualifies the silent auto-allow and
      # the allowlist fast-path. Scans the WHOLE token list (global region AND
      # post-subcommand args) so `git diff --ext-diff` and `git -c X=Y log`
      # are both rejected (#536, GHSA-9ccr-r5hg-74gf).
      def git_exec_vector?(tokens)
        tokens.drop(1).any? { |tok| git_exec_option?(tok) || git_exec_config_key?(tok) }
      end

      # A token is an exec-capable git OPTION when it is one of the exact flags
      # (or its `flag=value` form), or a glued short form of `-c`/`-C`/`-u`.
      def git_exec_option?(tok)
        GIT_EXEC_OPTION_FLAGS.any? do |f|
          tok == f ||
            tok.start_with?("#{f}=") ||
            (f.length == 2 && f.start_with?("-") && !f.start_with?("--") && tok.start_with?(f) && tok.length > 2)
        end
      end

      # A token names (or carries as a value) a command-executing config key.
      # Case-insensitive substring/pattern scan so the key trips whether it is a
      # bare token, a `-ckey=val`/`key=val` form, or a `--config-env key=ENV`.
      def git_exec_config_key?(tok)
        low = tok.downcase
        GIT_EXEC_CONFIG_KEYS.any? { |k| low.include?(k) } ||
          GIT_EXEC_CONFIG_KEY_PATTERNS.any? { |re| re.match?(tok) }
      end

      # Read-only git: a safe subcommand (no global flags before it — `git -C`
      # falls to the prompt), never an output-writing flag (git log/diff/show
      # can write a file with --output/-o), never an exec-capable vector
      # (--ext-diff/--textconv/-c diff.external/… run a repo-config driver, #536),
      # branch/remote in their pure listing forms only.
      def safe_git?(tokens)
        return false if git_exec_vector?(tokens)

        sub = tokens[1]
        return false if sub.nil? || sub.start_with?("-")

        rest = tokens.drop(2)
        return false if git_write_flag?(rest)

        case sub
        when *GIT_READONLY_SUBCOMMANDS then true
        when "branch" then rest.all? { |t| GIT_BRANCH_READONLY_FLAGS.include?(t) }
        when "remote" then rest.empty? || rest == ["-v"] || rest == ["--verbose"]
        else false
        end
      end

      # approvals.readonly_commands entries extend the built-in set: a bare
      # name ("jq") matches that head, a multi-word entry ("docker ps")
      # matches those leading tokens exactly.
      def extra_match?(tokens, extra)
        Array(extra).any? do |entry|
          entry_tokens = entry.to_s.strip.split(/\s+/)
          !entry_tokens.empty? && tokens.first(entry_tokens.length) == entry_tokens
        end
      end
    end
  end
end
