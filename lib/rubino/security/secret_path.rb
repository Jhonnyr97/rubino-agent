# frozen_string_literal: true

module Rubino
  module Security
    # ONE "is this a secret/credential path?" predicate, shared by the tool
    # layer (read/grep/glob refuse to leak; write/edit refuse to clobber) and
    # the approval layer (Security::ApprovalPolicy#decide → :ask). Previously
    # the read side and the write side carried two parallel denylists; the
    # maintainer decision (#446) is that reading OR writing a secret both
    # require the SAME explicit user approval over the SAME set — so the set
    # and the predicate live here, once.
    #
    # The gate itself is in ApprovalPolicy/ToolExecutor (interactive →
    # approval dropdown; approved → tool proceeds; denied → refused; headless →
    # fails closed). This module is pure detection — it never prompts, blocks,
    # or touches IO beyond symlink resolution.
    module SecretPath
      module_function

      # Credential/secret BASENAMES, in any directory.
      BASENAME_RE = /
        \A\.env(\..+)?\z | \A\.envrc\z |
        \A\.netrc\z | \A\.pgpass\z | \A\.npmrc\z | \A\.pypirc\z |
        \A\.git-credentials\z |
        \A\.bashrc\z | \A\.zshrc\z | \A\.profile\z | \A\.bash_profile\z | \A\.zprofile\z
      /x

      # Home-relative credential subtrees (resolved against $HOME).
      HOME_PREFIXES = [
        ".ssh", ".aws", ".gnupg", ".kube", ".docker", ".azure",
        ".config/gh", ".config/gcloud"
      ].freeze

      # Absolute system paths / prefixes.
      SYSTEM_PATHS    = ["/etc/sudoers", "/etc/passwd", "/etc/shadow"].freeze
      SYSTEM_PREFIXES = ["/etc/sudoers.d", "/etc/systemd"].freeze

      # Returns the matched-secret category string (truthy) for a secret path,
      # or nil for a normal file. `path` may be relative or absolute; it is
      # resolved through every symlink first so an in-workspace link to ~/.ssh
      # can't slip past the basename/prefix checks.
      def category(path)
        base   = File.basename(path.to_s)
        target = canonical_path(path) || File.expand_path(path.to_s)

        return "credential file (#{base})" if base.match?(BASENAME_RE)
        if (cat = denied_path_category(target, base))
          return cat
        end

        agent_home_category(path, base, target)
      end

      # True when `path` is a secret. Thin boolean wrapper over #category.
      def secret?(path)
        !category(path).nil?
      end

      # Absolute-path / prefix matches (SSH keys, cloud creds, /etc system
      # files), compared against the symlink-resolved target.
      def denied_path_category(target, base)
        home = File.expand_path("~")
        HOME_PREFIXES.each do |rel|
          return "credential directory (~/#{rel})" if under_path?(target, File.join(home, rel))
        end
        return "system file (#{base})" if SYSTEM_PATHS.include?(target)

        SYSTEM_PREFIXES.each do |prefix|
          return "system path (#{prefix})" if under_path?(target, prefix)
        end
        nil
      end

      # Agent-home (~/.rubino) auth/secret material: the home .env, the token
      # store sqlite DB, *oauth* files, mcp-tokens/, and *.key/*.pem material.
      def agent_home_category(path, base, target)
        return unless under_agent_home?(path)

        lower = target.downcase
        return unless base == ".env" || base.match?(BASENAME_RE) ||
                      base == "rubino.sqlite3" || base.end_with?(".sqlite3") ||
                      lower.include?("oauth") || lower.include?("/mcp-tokens/") ||
                      base.end_with?(".key") || base.end_with?(".pem")

        "agent-home secret (#{base})"
      end

      # True when +target+ is +root+ itself or sits under it.
      def under_path?(target, root)
        target == root || target.start_with?("#{root}#{File::SEPARATOR}")
      end

      # Resolves `path` through every symlink to its canonical destination,
      # re-joining the missing tail for a not-yet-created target. Mirrors
      # Tools::Base#canonical_path so the write-creates-new-file flow resolves
      # to the same place the tool will write.
      def canonical_path(path)
        return nil if path.nil? || path.to_s.empty?

        expanded = File.expand_path(path.to_s)
        return File.realpath(expanded) if File.exist?(expanded)

        ancestor = expanded
        tail     = []
        until File.exist?(ancestor)
          parent = File.dirname(ancestor)
          break if parent == ancestor

          tail.unshift(File.basename(ancestor))
          ancestor = parent
        end
        return nil unless File.exist?(ancestor)

        File.join(File.realpath(ancestor), *tail)
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        nil
      end

      # True when `path` resolves under the Rubino home directory.
      def under_agent_home?(path)
        home = Rubino.home_path
        return false if home.nil? || home.to_s.empty?

        home_real   = (File.realpath(home) if File.exist?(home)) || File.expand_path(home)
        target_real = canonical_path(path)
        return false unless target_real

        target_real == home_real || target_real.start_with?("#{home_real}#{File::SEPARATOR}")
      rescue StandardError
        false
      end
    end
  end
end
