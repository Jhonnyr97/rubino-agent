# frozen_string_literal: true

module Rubino
  module Security
    # ONE "is this a secret/credential path?" predicate for the WRITE-side
    # approval gate (Security::ApprovalPolicy#decide → :ask when a write/edit/
    # multi_edit/apply_patch targets a secret). Writing/clobbering a secret
    # requires explicit user approval; READING one is allowed unprompted (the
    # field norm, #480) and has no gate, so this predicate is no longer
    # consulted on the read path.
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

      # Common secret-bearing project-local environment file basenames blocked
      # on the structured READ path (read/grep), ported 1:1 from Hermes'
      # `agent/file_safety._BLOCKED_PROJECT_ENV_BASENAMES`. Deliberately an
      # EXACT set (not BASENAME_RE) so `.env.example` — the documented-shape
      # substitute — is NOT blocked, matching Hermes.
      BLOCKED_PROJECT_ENV_BASENAMES = [
        ".env", ".env.local", ".env.development",
        ".env.production", ".env.test", ".env.staging", ".envrc"
      ].to_set.freeze

      # Agent-home credential-store basenames blocked on the structured READ
      # path, mirroring Hermes' `get_read_block_error` credential_file_names
      # (auth.json / .anthropic_oauth.json / .env / mcp-tokens/ live under the
      # agent home). rubino's token store is rubino.sqlite3.
      BLOCKED_HOME_CREDENTIAL_BASENAMES = [
        ".env", "auth.json", "auth.lock",
        ".anthropic_oauth.json", "rubino.sqlite3"
      ].to_set.freeze

      # $HOME-relative credential FILES blocked on the structured READ path.
      # Ported from Hermes' `build_write_denied_paths` (file_safety.py:35-58):
      # the SSH key/identity files (`~/.ssh/{id_rsa,id_ed25519,authorized_keys,
      # config}`), `~/.netrc`, and `~/.git-credentials`. QA finding: these
      # leaked because they were only on the WRITE denylist, so a `read` of
      # `~/.ssh/id_rsa` etc. returned the key material — and the redactor's
      # uppercase-only ENV_ASSIGN_RE misses lowercase `aws_secret_access_key`.
      # rubino has no Anthropic PKCE store; its OAuth/credential equivalents
      # live under the agent home (~/.rubino) and are already covered above.
      BLOCKED_HOME_CREDENTIAL_FILES = [
        File.join(".ssh", "id_rsa"),
        File.join(".ssh", "id_ed25519"),
        File.join(".ssh", "authorized_keys"),
        File.join(".ssh", "config"),
        ".netrc",
        ".git-credentials"
      ].freeze

      # $HOME-relative credential DIRECTORIES blocked on the structured READ
      # path (anything inside is treated as secret). Started from Hermes'
      # `build_write_denied_prefixes` (file_safety.py:66-82): `~/.ssh` and
      # `~/.aws`. This is what blocks `~/.aws/credentials` (the lowercase
      # `aws_secret_access_key` the redactor doesn't mask).
      #
      # Extended (#537) so the READ deny-set covers the same home-credential
      # stores the WRITE-side detector (HOME_PREFIXES) already treats as secret:
      # `~/.kube` (bearer tokens in config), `~/.docker` (registry auth in
      # config.json), `~/.config/gh` (GitHub tokens in hosts.yml), `~/.gnupg`
      # (private keyrings) and `~/.azure` (cloud creds). Previously read-allowed
      # and unredacted, so those secrets reached the model. Defense-in-depth
      # layered on the trust model — NOT a complete boundary (the shell tool
      # runs as the same OS user and can still read them).
      BLOCKED_HOME_CREDENTIAL_DIRS = [
        ".ssh", ".aws", ".kube", ".docker", ".gnupg", ".azure",
        File.join(".config", "gh")
      ].freeze

      # Credential BASENAMES blocked on the structured READ path wherever they
      # sit — HOME or project-local (#537). `.netrc`/`.git-credentials` were
      # only blocked at their exact $HOME path, so a project-local copy was
      # read-allowed and unredacted. Defense-in-depth, not a boundary.
      BLOCKED_CREDENTIAL_BASENAMES = [".netrc", ".git-credentials"].to_set.freeze

      # Returns a model-facing error string when a structured READ (read/grep)
      # targets a denied secret/credential path, or nil when the read is
      # allowed. Ported 1:1 from Hermes' `get_read_block_error` plus the
      # home credential files/dirs Hermes write-denies (file_safety.py:35-82):
      # the project-local .env family ANYWHERE on disk, the agent-home
      # credential stores and the mcp-tokens/ tree, and the user's SSH/AWS/
      # kube/docker/gnupg/azure/gh credential stores under $HOME (#537), plus
      # `.netrc`/`.git-credentials` wherever they sit (HOME or project-local).
      #
      # **NOT a security boundary** — the shell runs as the same OS user and
      # can still `cat .env`, where the value is REDACTED (see Redactor).
      # The read block is defense-in-depth: it returns a clear error that
      # most models respect, and surfaces an audit trail. Mirrors the framing
      # in Hermes' module docstring.
      def read_block_error(path)
        base   = File.basename(path.to_s)
        target = canonical_path(path) || File.expand_path(path.to_s)

        if under_agent_home?(path) && (BLOCKED_HOME_CREDENTIAL_BASENAMES.include?(base) ||
             base.end_with?(".sqlite3") || target.downcase.include?("oauth") ||
             target.downcase.include?("#{File::SEPARATOR}mcp-tokens#{File::SEPARATOR}") ||
             under_path?(target, File.join(canonical_home, "mcp-tokens")))
          return "Access denied: #{path} is a Rubino credential store and " \
                 "cannot be read directly. Provider tools consume these " \
                 "credentials through internal channels. (Defense-in-depth — " \
                 "not a security boundary; the shell tool can still bypass.)"
        end

        if BLOCKED_PROJECT_ENV_BASENAMES.include?(base)
          return "Access denied: #{path} is a secret-bearing environment file " \
                 "and cannot be read to prevent credential leakage. If you need " \
                 "to check the file structure, read .env.example instead. " \
                 "(Defense-in-depth — not a security boundary; the shell tool " \
                 "can still bypass.)"
        end

        if BLOCKED_CREDENTIAL_BASENAMES.include?(base) || home_credential_path?(target)
          return "Access denied: #{path} is a private credential store " \
                 "(SSH key, cloud/kube/docker/gh credentials, gnupg keyring, " \
                 "netrc, or git-credentials) and cannot be read to prevent " \
                 "credential leakage. (Defense-in-depth — not a security " \
                 "boundary; the shell tool can still bypass.)"
        end

        nil
      end

      # True when the symlink-resolved +target+ is one of the $HOME-relative
      # credential files, or sits inside one of the blocked credential
      # directories (~/.ssh, ~/.aws). Mirrors Hermes' write-deny exact-path +
      # prefix split, applied here to the READ gate.
      def home_credential_path?(target)
        home = File.expand_path("~")
        return true if BLOCKED_HOME_CREDENTIAL_FILES.any? { |rel| target == File.join(home, rel) }

        BLOCKED_HOME_CREDENTIAL_DIRS.any? { |rel| under_path?(target, File.join(home, rel)) }
      end

      # Resolved Rubino home dir, for the mcp-tokens/ subtree match above.
      def canonical_home
        home = Rubino.home_path
        return "" if home.nil? || home.to_s.empty?

        (File.realpath(home) if File.exist?(home)) || File.expand_path(home)
      rescue StandardError
        ""
      end

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
