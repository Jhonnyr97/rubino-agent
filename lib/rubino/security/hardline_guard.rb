# frozen_string_literal: true

module Rubino
  module Security
    # Hardline (unconditional) blocklist — a floor BELOW yolo.
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
        [/\brm\s+(?:-\S*\s+)*(?:\/|\/\*)(?:\s|$)/, "recursive delete of root filesystem"],
        # rm -r/-rf targeting a protected system directory
        [%r{\brm\s+(?:-\S*\s+)*(?:/home|/root|/etc|/usr|/var|/bin|/sbin|/boot|/lib)(?:/\*)?(?:\s|$)}, "recursive delete of system directory"],
        # rm targeting the home directory (~ or $HOME)
        [/\brm\s+(?:-\S*\s+)*(?:~|\$home)(?:\/?|\/\*)?(?:\s|$)/, "recursive delete of home directory"],
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
      def detect(command)
        normalized = normalize(command)
        HARDLINE_PATTERNS.each do |regex, description|
          return [true, description] if normalized.match?(regex)
        end
        return [true, "sudo password guessing via stdin (sudo -S)"] if sudo_stdin?(normalized)

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

      # Minimal normalization: collapse runs of spaces/tabs (newlines kept so
      # the command-separator anchors still fire), trim, and lowercase so
      # trivial obfuscation (extra spaces, case) doesn't slip through.
      # Deliberately NOT a full ANSI/Unicode normalizer — over-engineering for
      # the hardline floor.
      def normalize(command)
        command.to_s.gsub(/[ \t]+/, " ").strip.downcase
      end
    end
  end
end
