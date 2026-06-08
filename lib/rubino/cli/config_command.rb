# frozen_string_literal: true

require "thor"

module Rubino
  module CLI
    # Subcommands for managing configuration
    class ConfigCommand < Thor
      # Clean `tree`/help label instead of the underscored
      # "rubino:c_l_i:config_command" Thor derives from the class name (F12).
      namespace "rubino config"

      def self.exit_on_failure?
        true
      end

      desc "get KEY", "Get a configuration value (dot-notation)"
      def get(key)
        # Resolve against the effective config (file merged over defaults), the
        # same source `show` and the running agent use, so default-valued keys
        # are returned instead of falsely reported "not found" (issue #36).
        # A scalar intermediate node (e.g. descending into a String) has no
        # #dig; treat such a path as "not found" rather than crashing.
        value =
          begin
            Rubino.configuration.dig(*key.split("."))
          rescue TypeError
            nil
          end
        if value.nil?
          Rubino.ui.warning("Key '#{key}' not found")
        else
          Rubino.ui.info("#{key} = #{value}")
        end
      end

      desc "set KEY VALUE", "Set a configuration value (dot-notation)"
      def set(key, value)
        writer = Config::Writer.new(config_path: config_path)
        writer.set(key, value)
        Rubino.ui.success("#{key} = #{value}")
      rescue ConfigurationError => e
        Rubino.ui.error(e.message)
        exit(1)
      end

      desc "show", "Show full configuration"
      def show
        config = Rubino.configuration.raw
        Rubino.ui.info(config.to_yaml)
      end

      desc "path", "Show config file path"
      def path
        Rubino.ui.info(config_path)
      end

      private

      # Resolve through the Loader so config get/set/path operate on exactly
      # the file the server loads (RUBINO_HOME-aware), not a recomputed
      # File.join off a YAML default.
      def config_path
        Config::Loader.new.config_path
      end
    end
  end
end
