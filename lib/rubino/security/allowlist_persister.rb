# frozen_string_literal: true

module Rubino
  module Security
    # Persists an approved rule value to `security.command_allowlist` so it
    # survives a process restart and pre-approves future sibling commands
    # through the existing CommandAllowlist (prefix start_with?) path.
    #
    # Mirrors the reference save_permanent_allowlist,
    # which writes pattern keys to `command_allowlist` in config.yaml, and the
    # resolve-time persistence on the gateway path (:1342-1351).
    #
    # Append-unique: an already-listed value is a no-op (no duplicate rows, no
    # rewrite). The write goes through Config::Writer (dot-notation -> YAML) and
    # ALSO updates the live Rubino.configuration so a CommandAllowlist built
    # in the same process immediately sees the new prefix without a reload.
    #
    # SCOPING NOTE: Config::Writer writes the process-global config.yml. This
    # assumes a single-process / single-home deployment, so process-global ==
    # per-user here — acceptable. For any SHARED-server deployment, `always_*`
    # persistence would need per-user config scoping (or web `always` treated as
    # session-only); do NOT rely on this writer as-is in a multi-user process.
    module AllowlistPersister
      KEY = "security.command_allowlist"

      module_function

      # Appends `value` to security.command_allowlist (unique). Returns the
      # resulting allowlist array. A blank value is a no-op.
      def persist(value, config: nil, config_path: nil)
        rule_value = value.to_s.strip
        return current_allowlist(config) if rule_value.empty?

        config ||= Rubino.configuration
        existing = current_allowlist(config)
        return existing if existing.include?(rule_value)

        updated = existing + [rule_value]
        Config::Writer.new(config_path: config_path || default_config_path).set(KEY, updated)
        # Keep the live config in sync so a CommandAllowlist built this process
        # sees the new prefix immediately (the writer only touches disk).
        config.set("security", "command_allowlist", updated)
        updated
      end

      def current_allowlist(config)
        (config || Rubino.configuration).security_command_allowlist.dup
      end

      def default_config_path
        Config::Loader.new.config_path
      end
    end
  end
end
