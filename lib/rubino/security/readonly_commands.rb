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
      GIT_BRANCH_READONLY_FLAGS = %w[
        -a -r -v -vv --list --all --remotes --show-current --verbose
        --merged --no-merged --color --no-color
      ].freeze

      # Mutating/executing flags that disqualify an otherwise-safe head.
      # Matched as exact token or `flag=value`.
      FORBIDDEN_FLAGS = {
        "find" => %w[-exec -execdir -ok -okdir -delete -fprintf -fprint -fprint0 -fls],
        "date" => %w[-s --set],
        "tree" => %w[-o]
      }.freeze

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
      # a write or an execution: redirection (>), backgrounding (&), command
      # substitution ($( or backtick in a live context), process substitution
      # (<( / >( )), comments, trailing backslash, unterminated quotes. Plain
      # `<` input redirection stays allowed. Single-quoted text is literal in
      # POSIX shells, so substitutions inside it are safe to keep.
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
          when "`", ">", "#"
            return nil
          when "$", "<"
            return nil if succ == "("

            current << char
          when ";", "\n", "|", "&"
            advance = flush_segment(char, succ, segments, current)
            return nil unless advance

            current = +""
            i += advance
            next
          else
            current << char
          end
          i += 1
        end
        segments << current
        segments.map(&:strip).reject(&:empty?)
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
      # date -s, tree -o). The user command allowlist reuses this to vet the
      # flags of a matched entry, so an allowlisted head (e.g. `git diff`) can
      # never smuggle an arbitrary write via `--output`.
      FLAG_VETTED_HEADS = (["git"] + FORBIDDEN_FLAGS.keys).freeze

      # True when `tokens` (a single already-split, non-chained segment whose
      # head matched a user allowlist entry) carries a write/exec flag that
      # disqualifies an otherwise-safe head. For non-vetted heads this is
      # always false — only the known mutator-capable heads are screened.
      # Pure flag inspection; it does NOT require the command to be read-only
      # overall (an allowlist entry is user-chosen), it only rejects the
      # specific output/exec flags that turn a read into a write/exec.
      def dangerous_flags?(tokens)
        head = tokens.first
        return false unless FLAG_VETTED_HEADS.include?(head)

        if head == "git"
          # An allowlisted git command (e.g. `git diff`) must never smuggle an
          # arbitrary write via --output/-o. Reject the write flags wherever
          # they appear after the subcommand; the user's subcommand choice
          # itself stays authoritative (we don't re-impose read-only-ness).
          git_write_flag?(tokens.drop(2))
        else
          !safe_flags?(head, tokens)
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

      # Read-only git: a safe subcommand (no global flags before it — `git -C`
      # falls to the prompt), never an output-writing flag (git log/diff/show
      # can write a file with --output/-o), branch/remote in their pure
      # listing forms only.
      def safe_git?(tokens)
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
