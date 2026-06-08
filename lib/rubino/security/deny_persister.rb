# frozen_string_literal: true

module Rubino
  module Security
    # Persists an explicit "deny always" verdict to the `permissions` map so it
    # survives a process restart and auto-denies future sibling commands through
    # ApprovalPolicy#decide, which evaluates a permissions:deny rule FIRST (before
    # any allow path — see approval_policy.rb step 2).
    #
    # The DENY counterpart to AllowlistPersister: same Config::Writer (dot-notation
    # -> YAML) + live-config sync, but it writes into `permissions` instead of
    # `security.command_allowlist`, and the value is the verdict "deny" keyed by a
    # PatternMatcher-format pattern ("<tool> <glob>") rather than a bare prefix.
    #
    # The pattern is derived from the SAME PrefixDeriver rule the allow side uses,
    # so "deny always" is scoped consistently with "always allow":
    #   :prefix  -> "<tool> <head>*"     (e.g. "shell git*"  — denies every sibling)
    #   :command -> "<tool> <command>"   (e.g. "shell rm -rf /tmp/x" — exact)
    #   :pattern -> "<tool> <command>"   (a dangerous-pattern description is not a
    #                                     command glob, so deny the exact command)
    #
    # Append-unique: an already-present "<pattern>": "deny" entry is a no-op.
    #
    # SCOPING NOTE: identical to AllowlistPersister — Config::Writer writes the
    # process-global config.yml. Fine for a single-process / single-home setup; a
    # shared-server deployment would need per-user config scoping.
    module DenyPersister
      KEY = "permissions"
      DENY = "deny"

      module_function

      # Persists a permissions:deny rule for `pattern` (unique). Returns the
      # resulting permissions hash. A blank pattern is a no-op.
      def persist(pattern, config: nil, config_path: nil)
        key = pattern.to_s.strip
        return current_permissions(config) if key.empty?

        config ||= Rubino.configuration
        existing = current_permissions(config)
        return existing if existing[key] == DENY

        updated = existing.merge(key => DENY)
        Config::Writer.new(config_path: config_path || default_config_path).set(KEY, updated)
        # Keep the live config in sync so an ApprovalPolicy built this process
        # sees the new deny rule immediately (the writer only touches disk).
        config.set(KEY, updated)
        updated
      end

      # The PatternMatcher-format key a (tool, rule, command) "deny always"
      # persists as. Mirrors the allow side's scoping: a derivable :prefix denies
      # the whole prefix class ("<tool> <head>*"); everything else denies the
      # exact command ("<tool> <command>"). Nil when there is nothing to key on.
      def pattern_for(tool:, rule:, command:)
        cmd = command.to_s.strip
        if rule&.kind == :prefix && !rule.value.to_s.strip.empty?
          "#{tool} #{rule.value.strip}*"
        elsif !cmd.empty?
          "#{tool} #{cmd}"
        end
      end

      def current_permissions(config)
        ((config || Rubino.configuration).dig("permissions") || {}).dup
      end

      def default_config_path
        Config::Loader.new.config_path
      end
    end
  end
end
