# frozen_string_literal: true

module Rubino
  module Security
    # Hardline (unconditional) blocklist — a floor BELOW yolo.
    #
    # SCOPE: this is a best-effort anti-ACCIDENT guard, NOT an anti-adversary
    # boundary. It stops the agent (or a careless user) from fat-fingering an
    # unrecoverable command via --yolo; it is NOT a sandbox and a determined
    # adversary with shell access can always evade a regex floor (base64, here-
    # docs, indirection, a written-then-run script). The real containment
    # boundary is the deferred OS-level sandbox (#290). Within that scope we
    # still canonicalize aggressively so trivial-but-common evasions (quoting,
    # trailing slashes, path-equivalents, ${HOME}) don't defeat the floor (#325).
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

      # sudo -S without a configured SUDO_PASSWORD is the model piping a
      # *guessed* password via stdin — a brute-force vector. Unconditional
      # block. Mirrors approval.py:_check_sudo_stdin_guard (:255).
      SUDO_STDIN_RE = /(?:^|[;&|`\n]|&&|\|\||\$\()\s*sudo\s+-s\b/

      module_function

      # Returns [true, description] when the command hits the hardline floor
      # (a HARDLINE_PATTERN or the sudo-stdin guard), else [false, nil].
      #
      # We match the patterns against TWO forms and OR the results: the raw
      # whitespace/case-normalized string, and a canonicalized form that strips
      # quoting, expands $HOME and collapses path-equivalents (see #canonicalize).
      # Canonicalization closes the trivial bypasses (rm -rf '/', /usr/, ${HOME},
      # //, /./); matching the raw form too is fail-open insurance for the rare
      # case where canonicalization rewrites a separator/redirect out of a match
      # (an anti-accident guard should never become LESS strict than before).
      def detect(command)
        normalized = normalize(command)
        canonical = canonicalize(normalized)
        HARDLINE_PATTERNS.each do |regex, description|
          return [true, description] if normalized.match?(regex) || canonical.match?(regex)
        end
        sudo_hit = sudo_stdin?(normalized) || sudo_stdin?(canonical)
        return [true, "sudo password guessing via stdin (sudo -S)"] if sudo_hit

        [false, nil]
      end

      # Convenience predicate for the post-approval defense-in-depth check in
      # ShellTool. Returns the description, or nil when the command is clear.
      def block_reason(command)
        blocked, description = detect(command)
        blocked ? description : nil
      end

      # sudo -S only fires the guard when no SUDO_PASSWORD is configured —
      # with one set, an internal transform legitimately injects -S elsewhere.
      def sudo_stdin?(normalized)
        return false if ENV.key?("SUDO_PASSWORD")

        normalized.match?(SUDO_STDIN_RE)
      end

      # Minimal normalization: strip shell line-continuations, collapse runs of
      # spaces/tabs (newlines kept so the command-separator anchors still fire),
      # trim, and lowercase so trivial obfuscation (extra spaces, case) doesn't
      # slip through. Deliberately NOT a full ANSI/Unicode normalizer —
      # over-engineering for the hardline floor.
      #
      # Line-continuation strip (#348): a backslash immediately before a newline
      # is a shell line-continuation — the two characters and any surrounding
      # whitespace fold the next line onto the current one. Pre-fix, normalize
      # kept the `\n` AND the trailing `\`, so `rm -rf \<newline>/` left `rm` and
      # `/` on separate lines with a stray backslash between them, and the
      # `\brm\s+...(?:/)` pattern (which needs rm adjacent to the target) missed
      # it. We join continued lines into a single space-separated command BEFORE
      # the rest of normalization so the patterns see `rm -rf /`.
      def normalize(command)
        joined = command.to_s.gsub(/\\\r?\n[ \t]*/, " ")
        joined.gsub(/[ \t]+/, " ").strip.downcase
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
        tokens = shell_split(normalized)
        return normalized if tokens.nil? # unbalanced quotes: fail open to raw

        cleaned = tokens.map { |tok| clean_token(tok) }
        "#{cleaned.join(" ")} "
      end

      # #348 follow-ups, applied BEFORE shell-splitting so the substituted text is
      # re-tokenized into the bare `rm -rf /` form the patterns expect:
      #   * ${IFS} word-splitting: `rm${IFS}-rf${IFS}/` joins rm to / with no
      #     real whitespace, so Shellwords sees ONE token `rm-rf/`. Replace any
      #     ${IFS} / $IFS occurrence with a space so the shell's own field-split
      #     is reproduced. (lowercased input -> ${ifs}/$ifs.)
      #   * ${HOME:-/} / ${HOME:=/} param-default: the `:-`/`:=` default is `/`,
      #     so a missing/empty HOME expands to the root filesystem. Collapse the
      #     whole `${home:-/}`-family braces to the default value so the root /
      #     home pattern fires.
      def expand_word_splits(text)
        out = text.gsub(/\$\{ifs\}|\$ifs\b/, " ")
        # ${home:-VALUE} / ${home:=VALUE} -> VALUE (the default the shell uses
        # when HOME is unset/empty). Captures the default path so `${home:-/}`
        # becomes `/` and the root-filesystem pattern matches.
        out.gsub(/\$\{home:[-=]([^}]*)\}/, '\1')
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
