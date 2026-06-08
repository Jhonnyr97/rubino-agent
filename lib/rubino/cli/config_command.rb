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
        writer = Config::Writer.new(config_path: config_path)
        value = writer.get(key)
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
