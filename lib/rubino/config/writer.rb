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

      # Sets a single key (dot-notation) to a value and persists
      def set(key_path, value)
        raw = load_raw
        keys = key_path.split(".")
        hash = raw

        keys[0..-2].each_with_index do |k, i|
          hash[k] ||= {}
          hash = hash[k]
          unless hash.is_a?(Hash)
            traversed = keys[0..i].join(".")
            raise ConfigurationError,
                  "cannot set '#{key_path}': '#{traversed}' is a scalar value, not a section"
          end
        end

        hash[keys.last] = coerce_value(value)
        save(raw)
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

      def load_raw
        if File.exist?(@config_path)
          YAML.safe_load(File.read(@config_path), permitted_classes: [Symbol]) || {}
        else
          {}
        end
      end

      def save(raw)
        FileUtils.mkdir_p(File.dirname(@config_path))
        File.write(@config_path, raw.to_yaml)
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
