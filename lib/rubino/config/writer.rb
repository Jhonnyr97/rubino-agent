# frozen_string_literal: true

require "yaml"
require "fileutils"

module Rubino
  module Config
    # Writes configuration changes back to the YAML file.
    class Writer
      def initialize(config_path:)
        @config_path = config_path
      end

      # Sets a single key (dot-notation) to a value and persists.
      #
      # The whole read-modify-write runs under an exclusive lock (and the write
      # is temp-file + atomic rename), so two concurrent `config set` of
      # different keys can't lose one another's update or tear config.yml into
      # unparseable YAML that bricks every later command.
      def set(key_path, value)
        Util::AtomicFile.update(@config_path) do |current|
          raw = parse_raw(current)
          keys = key_path.split(".")
          reject_scalar_over_section!(key_path, keys, raw, value)
          hash = raw

          keys[0..-2].each_with_index do |k, i|
            hash[k] ||= {}
            hash = hash[k]
            next if hash.is_a?(Hash)

            traversed = keys[0..i].join(".")
            raise ConfigurationError,
                  "cannot set '#{key_path}': '#{traversed}' is a scalar value, not a section"
          end

          hash[keys.last] = coerce_value(value)
          raw.to_yaml
        end
      end

      # Returns the value at a dot-notation key path
      def get(key_path)
        raw = load_raw
        keys = key_path.split(".")
        # A scalar intermediate node (e.g. a String) has no #dig; treat such a
        # path as "not found" rather than crashing with a TypeError.
        raw.dig(*keys)
      rescue TypeError
        nil
      end

      private

      # Refuses to clobber a structured SECTION (a Hash, in the defaults or in
      # the file already) with a SCALAR value (#259). `config set model foo`
      # used to overwrite the whole `model:` hash with the String "foo",
      # corrupting the config so badly that even `rubino doctor` then crashed
      # with a raw `String does not have #dig` TypeError. The default config is
      # the authoritative schema: if the value at this exact path is a Hash, the
      # path names a section the user must descend INTO (e.g. `model.default`),
      # not assign over. Replacing a section with another Hash (e.g. internal
      # callers writing the whole `permissions` map) is legitimate and allowed.
      def reject_scalar_over_section!(key_path, keys, raw, value)
        return if value.is_a?(Hash)

        existing = raw.dig(*keys)
        default = Defaults.dig(*keys)
        section = existing.is_a?(Hash) ? existing : default
        return unless section.is_a?(Hash)

        sample = section.keys.first
        hint = sample ? " (try '#{key_path}.#{sample}')" : ""
        raise ConfigurationError,
              "cannot set '#{key_path}': it is a config section, not a single value#{hint}"
      rescue TypeError
        # A scalar intermediate node has no #dig; the descent loop below raises
        # the precise "is a scalar value, not a section" error for that case.
        nil
      end

      def load_raw
        parse_raw(Util::AtomicFile.read_shared(@config_path))
      end

      # Parse the YAML text we were handed (the file contents under lock, or nil
      # when the file doesn't exist yet) into a Hash, mirroring load_raw's
      # nil/empty → {} contract.
      def parse_raw(text)
        return {} if text.nil? || text.empty?

        YAML.safe_load(text, permitted_classes: [Symbol]) || {}
      end

      def coerce_value(value)
        case value
        when "true" then true
        when "false" then false
        when "nil", "null" then nil
        when /\A\d+\z/ then value.to_i
        when /\A\d+\.\d+\z/ then value.to_f
        else value
        end
      end
    end
  end
end
