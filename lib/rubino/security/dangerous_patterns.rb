# frozen_string_literal: true

module Rubino
  module Security
    # Dangerous (recoverable-but-risky) command patterns — the layer ABOVE the
    # hardline floor. These are operations that can lose work, rewrite shared
    # history, escalate privilege, or touch system/credential files, but which
    # a user might legitimately want to run with confirmation. Unlike
    # HardlineGuard (catastrophic, no recovery path, never runs), a dangerous
    # match is meant to drive an :ask — yolo/approval CAN pass it through.
    #
    # This is deliberately DISTINCT from HardlineGuard: there is NO overlap.
    # Hardline owns "rm -rf /", "mkfs", "dd to /dev/sd*", shutdown/reboot,
    # fork bomb, kill-all, sudo -S guessing. DangerousPatterns owns the
    # recoverable cousins: recursive rm of NON-root paths, git force-push /
    # reset --hard, curl|sh, broad chmod/chown, writes into /etc, sudo with
    # privilege flags, find -delete, etc.
    #
    # Mirrors the reference approval module: DANGEROUS_PATTERNS and
    # detect_dangerous_command. A faithful CORE subset of the reference ~47
    # patterns — the important risk classes, not an exhaustive copy.
    module DangerousPatterns
      # Sensitive write targets (system config, block devices, ssh/credential
      # files). Mirrors approval.py:_SENSITIVE_WRITE_TARGET (:152) in spirit,
      # kept compact. /etc plus its macOS /private/etc mirror.
      SYSTEM_CONFIG_PATH = %r{(?:/etc/|/private/(?:etc|var|tmp)/)}.source.freeze
      SENSITIVE_WRITE_TARGET =
        %r{(?:#{SYSTEM_CONFIG_PATH}|/dev/sd|(?:~|\$home)/\.ssh/|(?:~|\$home)/\.(?:netrc|pgpass|npmrc|pypirc)\b)}.source.freeze

      # [regex, human description "pattern key"]. Matched against the
      # lowercased, whitespace-normalized command. The description doubles as
      # the persisted approval key in later slices (mirrors the reference pattern_key).
      PATTERNS = [
        # --- Recursive / forced delete of NON-root paths (root is hardline).
        #     -\S*r catches both -rf and the long --recursive form. ---
        [/\brm\s+-\S*r/, "recursive delete"],

        # --- Broad permission / ownership changes ---
        [/\bchmod\s+(?:-\S*\s+)*(?:777|666|o\+[rwx]*w|a\+[rwx]*w)\b/, "world/other-writable permissions"],
        [/\bchown\s+(?:-\S*)?r\s+root/, "recursive chown to root"],

        # --- Privilege escalation: sudo with non-interactive privilege flags ---
        # Plain `sudo cmd` is TTY-bound and excluded; these flags (stdin/
        # askpass/shell/list) are the agent-reachable escalation forms.
        # (sudo -S WITHOUT a configured password is hardline; this is the
        # broader, recoverable privilege-flag class.)
        [/\bsudo\b[^;|&\n]*?\s+(?:--stdin\b|-a\b|--askpass\b|-s\b)/,
         "sudo with privilege flag (stdin/askpass/shell/list)"],

        # --- Pipe remote content to a shell (curl|sh, wget|bash) ---
        [%r{\b(?:curl|wget)\b.*\|\s*(?:[/\w]*/)?(?:ba)?sh(?:\s|$|-c)}, "pipe remote content to shell"],
        [/\b(?:bash|sh|zsh|ksh)\s+<\s*<?\s*\(\s*(?:curl|wget)\b/, "execute remote script via process substitution"],

        # --- Write / overwrite into system or credential files ---
        [/>>?\s*["']?#{SENSITIVE_WRITE_TARGET}/, "overwrite system file via redirection"],
        [/\btee\b.*["']?#{SENSITIVE_WRITE_TARGET}/, "overwrite system file via tee"],
        [/\b(?:cp|mv|install)\b.*\s#{SYSTEM_CONFIG_PATH}/, "copy/move file into system config path"],
        [/\bsed\s+-\S*i.*\s#{SYSTEM_CONFIG_PATH}/, "in-place edit of system config"],

        # --- Service control ---
        [/\bsystemctl\s+(?:-\S+\s+)*(?:stop|restart|disable|mask)\b/, "stop/restart system service"],

        # --- Force-kill process sweeps (kill-all -1 is hardline) ---
        [/\bpkill\s+-9\b/, "force kill processes"],
        [/\bkillall\s+(?:-\S*\s+)*-(?:9|kill|sigkill)\b/, "force kill processes (killall -KILL)"],
        [/\bkillall\s+(?:-\S*\s+)*-r\b/, "kill processes by regex (killall -r)"],

        # --- find that deletes ---
        [%r{\bfind\b.*-exec(?:dir)?\s+(?:/\S*/)?rm\b}, "find -exec/-execdir rm"],
        [/\bfind\b.*-delete\b/, "find -delete"],
        [/\bxargs\s+.*\brm\b/, "xargs with rm"],

        # --- Git destructive / history-rewriting operations ---
        [/\bgit\s+reset\s+--hard\b/, "git reset --hard (destroys uncommitted changes)"],
        [/\bgit\s+push\b.*--force\b/, "git force push (rewrites remote history)"],
        [/\bgit\s+push\b.*\s-f\b/, "git force push short flag (rewrites remote history)"],
        [/\bgit\s+clean\s+-\S*f/, "git clean with force (deletes untracked files)"],
        [/\bgit\s+branch\s+-d\b/, "git branch force delete"],

        # --- Filesystem format / raw disk copy (the recoverable framings;
        #     mkfs and dd-to-/dev/sd* themselves are hardline) ---
        [/\bdd\s+.*if=/, "disk copy"],

        # --- Destructive SQL ---
        [/\bdrop\s+(?:table|database)\b/, "SQL DROP"],
        [/\bdelete\s+from\b(?![^\n]*\bwhere\b)/, "SQL DELETE without WHERE"],
        [/\btruncate\s+(?:table)?\s*\w/, "SQL TRUNCATE"]
      ].freeze

      module_function

      # Returns [true, pattern_key, description] when the command matches a
      # dangerous pattern, else [false, nil, nil]. The pattern_key and
      # description are the same string (the human-readable key) — the tuple
      # arity mirrors the reference detect_dangerous_command so later slices
      # can persist the key.
      def detect(command)
        normalized = normalize(command)
        PATTERNS.each do |regex, description|
          return [true, description, description] if normalized.match?(regex)
        end
        [false, nil, nil]
      end

      # Convenience predicate: true when the command hits a dangerous pattern.
      def dangerous?(command)
        detect(command).first
      end

      # Same normalization idiom as HardlineGuard: collapse spaces/tabs (keep
      # newlines so separator anchors fire), trim, lowercase. Trivial
      # obfuscation (extra spaces, case) doesn't slip through.
      def normalize(command)
        command.to_s.gsub(/[ \t]+/, " ").strip.downcase
      end
    end
  end
end
