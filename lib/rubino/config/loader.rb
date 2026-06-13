# frozen_string_literal: true

require "yaml"
require "fileutils"

module Rubino
  module Config
    class ConfigError < StandardError; end

    # Responsible for loading configuration from YAML files and environment.
    # Searches in order: project-local, user home, defaults.
    class Loader
      CONFIG_FILENAME = "config.yml"
      ENV_FILENAME = ".env"
      ENV_VAR_PATTERN = /\$\{([A-Z_][A-Z0-9_]*)\}/

      attr_reader :home_path, :config_path, :env_path

      # Single source of truth for the home directory: RUBINO_HOME when
      # set, else ~/.rubino. Rubino.home_path delegates here so the
      # server (which loads config via the Loader) and the CLI commands
      # (config/setup/doctor) resolve the SAME directory — previously the
      # server honoured $RUBINO_HOME while the CLI recomputed
      # File.join(Rubino.home_path, "config.yml") off the YAML
      # `paths.home` default (~/.rubino), a split brain at first boot.
      def self.default_home_path
        env = ENV["RUBINO_HOME"].to_s.strip
        env.empty? ? File.expand_path("~/.rubino") : File.expand_path(env)
      end

      def initialize(home_path: nil)
        @home_path = home_path || self.class.default_home_path
        @config_path = File.join(@home_path, CONFIG_FILENAME)
        @env_path = File.join(@home_path, ENV_FILENAME)
      end

      # Loads configuration from file, merging with defaults.
      #
      # Every way a config.yml can be unusable is normalized into a single
      # {ConfigError} with a clean, actionable message here — at the source —
      # so no raw Ruby/Psych backtrace can escape to the boot path (CFG-1 /
      # CFG-R2). Covers: a YAML syntax error, an alias/anchor reference
      # (safe_load rejects aliases by design), a config path that is a
      # directory or a symlink to one (Errno::EISDIR), a non-Hash top-level
      # (a bare scalar like `foo`, or a sequence), and any other read/parse
      # failure.
      def load
        raw = load_raw_config

        load_env_file if File.exist?(@env_path)

        deep_merge(Defaults.to_hash, expand_env_vars(raw))
      end

      # Returns true if a config file exists
      def config_exists?
        File.exist?(@config_path)
      end

      # Creates the initial config file with defaults
      def create_default_config!
        FileUtils.mkdir_p(@home_path)
        File.write(@config_path, Defaults.to_yaml)
        @config_path
      end

      private

      # Reads and parses the config file into a Hash, raising {ConfigError}
      # (never a raw Psych/Ruby exception) for any malformed shape. Returns an
      # empty Hash when no config file exists — a fresh install runs on the
      # defaults alone.
      def load_raw_config
        return {} unless File.exist?(@config_path)

        raw =
          begin
            YAML.safe_load_file(@config_path, permitted_classes: [Symbol])
          rescue Psych::SyntaxError => e
            raise ConfigError,
                  "Invalid YAML in #{@config_path} at line #{e.line}, column #{e.column}: #{e.problem}"
          rescue Psych::BadAlias
            raise ConfigError,
                  "Unsupported YAML alias/anchor in #{@config_path}. " \
                  "Remove the alias (`*name`) / anchor (`&name`) — config.yml must be plain data."
          rescue SystemCallError, IOError => e
            # A config path that is a directory (or a symlink to one) reads as
            # Errno::EISDIR; any other read failure (permissions, etc.) lands
            # here too. Both become a clean ConfigError.
            raise ConfigError, "#{@config_path} is a directory (or a symlink to one), not a config file." \
              if e.is_a?(Errno::EISDIR)

            raise ConfigError, "Cannot read #{@config_path}: #{e.message}"
          end

        # A well-formed YAML document whose top level is a scalar (`foo`) or a
        # sequence (`- a`) parses fine but is not a config mapping — merging it
        # into the defaults would blow up downstream. Reject it here with a
        # clear message instead.
        return {} if raw.nil?
        unless raw.is_a?(Hash)
          raise ConfigError,
                "#{@config_path} must be a YAML mapping of settings, " \
                "got a top-level #{raw.class.name.downcase} (#{raw.inspect[0, 40]})."
        end

        raw
      end

      def load_env_file
        File.readlines(@env_path).each do |line|
          line = line.strip
          next if line.empty? || line.start_with?("#")

          key, value = line.split("=", 2)
          next unless key && value

          ENV[key.strip] = strip_env_quotes(value.strip)
        end
      end

      # Strips matched surrounding single or double quotes (a common .env
      # convention: FOO="bar baz" → bar baz). Unbalanced quotes are preserved
      # verbatim so they aren't silently mangled.
      def strip_env_quotes(value)
        return value if value.length < 2

        first = value[0]
        last  = value[-1]
        return value[1..-2] if ['"', "'"].include?(first) && first == last

        value
      end

      def expand_env_vars(node)
        case node
        when Hash   then node.transform_values { |v| expand_env_vars(v) }
        when Array  then node.map { |v| expand_env_vars(v) }
        when String then node.gsub(ENV_VAR_PATTERN) { ENV[Regexp.last_match(1)] || "" }
        else node
        end
      end

      def deep_merge(base, override)
        base.merge(override) do |_key, old_val, new_val|
          if old_val.is_a?(Hash) && new_val.is_a?(Hash)
            deep_merge(old_val, new_val)
          else
            new_val
          end
        end
      end
    end
  end
end
