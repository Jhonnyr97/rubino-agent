# frozen_string_literal: true

module Rubino
  module Security
    # Hardline (unconditional) blocklist — a floor BELOW yolo.
    #
    # SCOPE: this is a best-effort anti-INCIDENT circuit-breaker, NOT an anti-
    # adversary boundary. It stops the agent (or a careless user) from running an
    # unrecoverable command via --yolo, INCLUDING the accidental/model-emitted
    # indirection forms that pad real commands — `echo $(rm -rf /)`, a backticked
    # `rm -rf /`, a `{ rm -rf /; }` brace-group. It is NOT a sandbox: a determined
    # adversary with shell access can always evade a regex floor (base64, here-
    # docs, an env-var/here-string built at runtime, a written-then-run script).
    # The real containment boundary is the deferred OS-level sandbox (#290).
    # Within that anti-incident scope we canonicalize aggressively — collapsing
    # trivial evasions (quoting, trailing slashes, path-equivalents, ${HOME}) AND
    # UNWRAPPING command substitution / backticks / brace-and-subshell groups so
    # the floor patterns match the INNER command — rather than widening the
    # blocklist patterns to chase each wrapper (whack-a-mole on a best-effort
    # string blocklist buys little; the boundary is #290, not the regex) (#325).
    #
    # Commands so catastrophic they must NEVER run via the agent, regardless
    # of --yolo, skip-approvals mode, a permissions:allow rule, or a
    # command_allowlist entry. Opting into yolo is the user trusting the agent
    # to move fast on their files and services — NOT trusting it to wipe the
    # disk or power the box off.
    #
    # The list is deliberately TINY: only things with no recovery path —
    # filesystem destruction rooted at / (or ~), raw block-device overwrites,
    # filesystem format, kernel shutdown/reboot, and fork-bomb / kill-all DoS.
    # Recoverable-but-costly operations (git reset --hard, rm -rf /tmp/x,
    # chmod -R 777, curl|sh) DO NOT belong here — they stay in the dangerous-
    # pattern layer where yolo/approval can pass them through. Adding anything
    # recoverable here is a false-positive that blocks legitimate work.
    #
    # Mirrors the reference approval module: HARDLINE_PATTERNS,
    # detect_hardline_command, the sudo-stdin guard, and the
    # "tiny, no recovery path" guidance.
    module HardlineGuard
      # Start-of-command anchor: matches positions where a shell begins
      # parsing a new command (start of string, after a separator, after a
      # subshell opener), optionally consuming leading wrappers (sudo, env
      # VAR=VAL, exec/nohup/setsid/time) so we don't false-positive on
      # "echo reboot" or "grep shutdown log". Mirrors approval.py:_CMDPOS.
      CMDPOS = /(?:^|[;&|\n`]|\$\()\s*(?:sudo\s+(?:-\S+\s+)*)?(?:env\s+(?:\w+=\S*\s+)*)?(?:(?:exec|nohup|setsid|time)\s+)*\s*/.source.freeze

      # [regex, human description]. Matched against the lowercased, whitespace-
      # normalized command. KEEP TINY — unrecoverable only.
      HARDLINE_PATTERNS = [
        # rm -r/-rf targeting the root filesystem (/ or /*)
        [%r{\brm\s+(?:-\S*\s+)*(?:/|/\*)(?:\s|$)}, "recursive delete of root filesystem"],
        # rm -r/-rf targeting a protected system directory
        [%r{\brm\s+(?:-\S*\s+)*(?:/home|/root|/etc|/usr|/var|/bin|/sbin|/boot|/lib)(?:/\*)?(?:\s|$)},
         "recursive delete of system directory"],
        # rm targeting the home directory (~ or $HOME)
        [%r{\brm\s+(?:-\S*\s+)*(?:~|\$home)(?:/?|/\*)?(?:\s|$)}, "recursive delete of home directory"],
        # Filesystem format
        [/\bmkfs(?:\.[a-z0-9]+)?\b/, "format filesystem (mkfs)"],
        # dd to a raw block device
        [%r{\bdd\b[^\n]*\bof=/dev/(?:sd|nvme|hd|mmcblk|vd|xvd|disk|loop)[a-z0-9]*}, "dd to raw block device"],
        # Redirect to a raw block device (echo x > /dev/sda)
        [%r{>\s*/dev/(?:sd|nvme|hd|mmcblk|vd|xvd|disk|loop)[a-z0-9]*\b}, "redirect to raw block device"],
        # chmod/chown -R on the root filesystem
        [%r{\b(?:chmod|chown)\s+(?:-\S*\s+)*-\S*r\S*\s+\S+\s+/(?:\s|$)}, "recursive chmod/chown of root filesystem"],
        # Fork bomb (classic shell form, whitespace-tolerant)
        [/:\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:/, "fork bomb"],
        # Kill every process on the system
        [/\bkill\s+(?:-\S+\s+)*-1\b/, "kill all processes"],
        # System shutdown / reboot / halt / poweroff (anchored to cmd position)
        [/#{CMDPOS}(?:shutdown|reboot|halt|poweroff)\b/, "system shutdown/reboot"],
        [/#{CMDPOS}init\s+[06]\b/, "init 0/6 (shutdown/reboot)"],
        [/#{CMDPOS}systemctl\s+(?:poweroff|reboot|halt|kexec)\b/, "systemctl poweroff/reboot"],
        [/#{CMDPOS}telinit\s+[06]\b/, "telinit 0/6 (shutdown/reboot)"]
      ].freeze

      # sudo -S / sudo --stdin without a configured SUDO_PASSWORD is the model
      # piping a *guessed* password via stdin — a brute-force vector.
      # Unconditional block. Mirrors approval.py:_check_sudo_stdin_guard (:255).
      #
      # CASE-SENSITIVE on purpose: `-S` (capital — read the password from STDIN)
      # is the dangerous form this guard owns; `-s` (lowercase — run $SHELL) is a
      # DIFFERENT flag and must NOT be flagged here (sudo's own privilege-flag
      # handling lives in DangerousPatterns, not the hardline floor). The
      # previous `-s\b` regex relied on #normalize lowercasing the command, which
      # both over-matched `sudo -s` AND failed to anchor on the real intent — and
      # it missed the `--stdin` long form entirely. We now match against a
      # case-PRESERVED form (#sudo_stdin?): `-S` and combined short clusters
      # ending in S (`-kS`, `-nS`), plus the GNU `--stdin` long form.
      SUDO_STDIN_RE = /(?:^|[;&|`\n]|&&|\|\||\$\()\s*sudo\s+(?:-[a-zA-Z]*S(?![a-zA-Z])|--stdin\b)/

      module_function

      # Returns [true, description] when the command hits the hardline floor
      # (a HARDLINE_PATTERN or the sudo-stdin guard), else [false, nil].
      #
      # We match the patterns against TWO forms and OR the results: the raw
      # whitespace/case-normalized string, and a canonicalized form that strips
      # quoting, expands $HOME, collapses path-equivalents, and UNWRAPS command
      # substitution / backticks / brace-and-subshell groups (see #canonicalize).
      # Canonicalization closes the trivial bypasses (rm -rf '/', /usr/, ${HOME},
      # //, /./) and the indirection bypasses ($(rm -rf /), `rm -rf /`,
      # { rm -rf /; }); matching the raw form too is fail-open insurance for the
      # rare case where canonicalization rewrites a separator/redirect out of a
      # match (an anti-incident guard should never become LESS strict than before).
      def detect(command)
        normalized = normalize(command)
        canonical = canonicalize(normalized)
        HARDLINE_PATTERNS.each do |regex, description|
          return [true, description] if normalized.match?(regex) || canonical.match?(regex)
        end
        # The sudo-stdin guard is CASE-SENSITIVE (`-S` ≠ `-s`), so it must NOT see
        # the lowercased normalized/canonical forms. Match it against a
        # whitespace-normalized but case-PRESERVED form of the raw command.
        sudo_hit = sudo_stdin?(normalize_case_preserving(command))
        return [true, "sudo password guessing via stdin (sudo -S)"] if sudo_hit

        [false, nil]
      end

      # Convenience predicate for the post-approval defense-in-depth check in
      # ShellTool. Returns the description, or nil when the command is clear.
      def block_reason(command)
        blocked, description = detect(command)
        blocked ? description : nil
      end

      # sudo -S / --stdin only fires the guard when no SUDO_PASSWORD is
      # configured — with one set, an internal transform legitimately injects
      # -S elsewhere. The input MUST be case-preserved (see #detect): the regex
      # discriminates `-S` from `-s` on case.
      def sudo_stdin?(case_preserved)
        return false if ENV.key?("SUDO_PASSWORD")

        case_preserved.match?(SUDO_STDIN_RE)
      end

      # Minimal normalization: strip shell line-continuations, collapse runs of
      # spaces/tabs (newlines kept so the command-separator anchors still fire),
      # trim, and lowercase so trivial obfuscation (extra spaces, case) doesn't
      # slip through. Deliberately NOT a full ANSI/Unicode normalizer —
      # over-engineering for the hardline floor.
      #
      # Line-continuation strip (#348): a backslash immediately before a newline
      # is a shell line-continuation — the two characters fold the next line onto
      # the current one with NO intervening character. The shell deletes the
      # `\<newline>` pair entirely; it does NOT insert a space. Pre-fix we replaced
      # it with a SPACE, so `rm -r\<newline>f /` became `rm -r f /` — the `-r` and
      # `f` split into two tokens and the `\brm\s+(?:-\S*\s+)*/` pattern (which
      # needs the flags glued) MISSED it, letting an unrecoverable `rm -rf /` past
      # the floor (#348 residual). Replace the continuation with the EMPTY string
      # so `rm -r\<newline>f /` folds to `rm -rf /` exactly as the shell sees it.
      # (Trailing whitespace after the backslash is NOT part of the continuation
      # and is left for the space-collapse below.)
      def normalize(command)
        normalize_case_preserving(command).downcase
      end

      # Same whitespace normalization as #normalize (line-continuation strip,
      # space/tab collapse, trim) but WITHOUT lowercasing. Used only by the
      # case-sensitive sudo-stdin guard so `-S` (stdin password) stays
      # distinguishable from `-s` (start shell).
      def normalize_case_preserving(command)
        joined = command.to_s.gsub(/\\\r?\n/, "")
        joined.gsub(/[ \t]+/, " ").strip
      end

      # Canonicalize the (already normalized) command so common, trivial
      # evasions of the hardline patterns collapse onto the bare forms the
      # patterns expect. This is the #325 hardening: instead of growing the
      # pattern list to chase each quoting/path-equivalent variant, we normalize
      # the INPUT the patterns see. Steps, per token:
      #   1. Shell-word split (Shellwords) — strips quotes so '/' "/" '/usr'
      #      collapse to /, /usr. Unbalanced quotes raise ArgumentError; we then
      #      FALL BACK to the raw normalized string (fail-open — never raise out
      #      of a security check).
      #   2. Expand a TINY fixed env set ($HOME, ${HOME}, "$HOME", $home, ${home})
      #      to ~ so the home-directory pattern fires on the brace/quote forms
      #      the (?:~|\$home) regex misses.
      #   3. For path-shaped tokens (start with / or ~), Pathname#cleanpath
      #      (pure-string, no FS touch) collapses /usr/ -> /usr, // -> /,
      #      /. -> /, /./ -> /, /home/../ -> / .
      # Re-join with single spaces and append a trailing space so a token-final
      # `/` still satisfies the patterns' (?:\s|$) anchor.
      def canonicalize(normalized)
        require "shellwords"
        require "pathname"
        normalized = expand_word_splits(normalized)
        normalized = unwrap_substitutions(normalized)
        tokens = shell_split(normalized)
        return normalized if tokens.nil? # unbalanced quotes: fail open to raw

        cleaned = tokens.map { |tok| clean_token(tok) }
        "#{cleaned.join(" ")} "
      end

      # Unwrap command-substitution / backtick / brace-and-subshell indirection so
      # the floor patterns see the INNER command at command position (#325 gap).
      # A model or a careless user can pad a catastrophic command with a wrapper
      # the rm/dd/mkfs patterns don't anchor on — `$(rm -rf /)`, `` `rm -rf /` ``,
      # `{ rm -rf /; }`, `echo $(rm -rf /*)`. The wrapper merely RUNS the inner
      # text, so unwrapping it to bare text is faithful to what the shell executes.
      #
      # We turn each wrapper delimiter into a space, which promotes the inner
      # command to the top level of the canonical string. Crucially we DO NOT
      # touch `${...}` PARAMETER expansion (handled by #expand_word_splits /
      # #clean_token) — only the `$(` COMMAND-substitution opener — so `${HOME}`
      # and `${IFS}` keep their meaning. Applied repeatedly (capped) so nested
      # `$(echo $(rm -rf /))` flattens too. Fail-open: a runaway input just stops
      # after the cap and matching proceeds on whatever it reached.
      def unwrap_substitutions(text)
        5.times do
          before = text
          # $(  ... )  command substitution. `$(` opener (NOT `${`), and bare
          # `)`/`(` subshell parens -> spaces. The negative lookbehind keeps
          # `${...}` intact while still splitting `$(`.
          text = text.gsub("$(", " ").gsub(/(?<!\$)[()]/, " ")
          # backtick command substitution -> spaces (open and close).
          text = text.gsub("`", " ")
          # `{ ... ; }` brace group: a brace GROUP delimiter is a `{` followed by
          # whitespace and a closing `}` at word boundary, plus the command-
          # terminating `;` — all separators, not part of the command. Map them to
          # spaces so the inner `rm -rf /` lands at command position. We DELIBERATELY
          # do NOT touch a `{`/`}` that is part of `${...}` parameter expansion
          # (no surrounding space) so `${HOME}`/`${IFS}` keep their meaning.
          text = text.gsub(/(?<=\s|\A){\s/, "  ").gsub(/(?<=\s)}/, " ")
          text = text.gsub(";", " ")
          break if text == before
        end
        text
      end

      # #348 follow-ups, applied BEFORE shell-splitting so the substituted text is
      # re-tokenized into the bare `rm -rf /` form the patterns expect:
      #   * ${IFS} word-splitting: `rm${IFS}-rf${IFS}/` joins rm to / with no
      #     real whitespace, so Shellwords sees ONE token `rm-rf/`. Replace any
      #     ${IFS} / $IFS occurrence with a space so the shell's own field-split
      #     is reproduced. (lowercased input -> ${ifs}/$ifs.)
      #   * ${IFS:0:1} substring form (#348 residual): `${IFS:OFFSET:LENGTH}`
      #     takes a slice of $IFS — `${IFS:0:1}` is its first char (a space). It is
      #     the SAME field-split trick as ${IFS}; `rm${IFS:0:1}-rf${IFS:0:1}/` must
      #     also collapse to spaces. Match the brace-with-offset form too.
      #   * ${VAR:-/} / ${VAR:=/} param-default (#348 residual): the `:-`/`:=`
      #     default is used when VAR is unset/empty. The pre-fix only handled the
      #     literal name `home`; ANY unset varname works (`${X:-/}`, `${FOO:-/}`),
      #     so an attacker just picks a name that is unset and the default `/`
      #     expands to the root filesystem. Collapse `${<anyname>:-VALUE}` /
      #     `${<anyname>:=VALUE}` to its default VALUE so the root/home pattern
      #     fires regardless of the chosen variable name.
      def expand_word_splits(text)
        # ${ifs}, $ifs, and the ${ifs:OFFSET:LEN} substring form all -> a space.
        out = text.gsub(/\$\{ifs(?::\d+(?::\d+)?)?\}|\$ifs\b/, " ")
        # ${VAR:-VALUE} / ${VAR:=VALUE} -> VALUE (the default the shell uses when
        # VAR is unset/empty), for ANY variable name. Captures the default path so
        # `${x:-/}` becomes `/` and the root-filesystem pattern matches.
        out.gsub(/\$\{[a-z_][a-z0-9_]*:[-=]([^}]*)\}/, '\1')
      end

      # Shell-word split, or nil on unbalanced quotes (caller falls back to raw).
      def shell_split(normalized)
        Shellwords.split(normalized)
      rescue ArgumentError
        nil
      end

      # Expand the tiny HOME env set, then cleanpath absolute-path tokens.
      def clean_token(tok)
        # $HOME / ${HOME} / $home / ${home} -> ~ (Shellwords already stripped the
        # surrounding quotes of "$HOME"). Only when the token IS (or starts) the
        # HOME ref, so we don't rewrite an unrelated $homedir.
        tok = tok.sub(%r{\A\$\{?home\}?(?=\z|/)}, "~")
        return tok unless tok.start_with?("/")

        # Pure-string path cleanup: /usr/ -> /usr, // -> /, /. -> /, /home/../ -> /.
        Pathname.new(tok).cleanpath.to_s
      end
    end
  end
end
