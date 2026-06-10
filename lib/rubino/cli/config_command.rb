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

      desc "get KEY", "Get a configuration value (dot-notation; secrets masked)"
      def get(key)
        self.class.render_get(key, ui: Rubino.ui)
      end

      # ONE get rendering for both surfaces (#187): this CLI verb and the
      # in-chat `/config get` (Commands::Executor). Resolves against the
      # effective config (file merged over defaults), the same source `show`
      # and the running agent use, so default-valued keys are returned instead
      # of falsely reported "not found" (issue #36). A scalar intermediate
      # node (e.g. descending into a String) has no #dig; treat such a path as
      # "not found" rather than crashing. Secret-named keys render masked.
      def self.render_get(key, ui:)
        value =
          begin
            Rubino.configuration.dig(*key.split("."))
          rescue TypeError
            nil
          end
        if value.nil?
          ui.warning("Key '#{key}' not found")
        else
          ui.info("#{key} = #{redact(value, key: key.split(".").last)}")
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

      desc "show", "Show full configuration (secrets masked)"
      def show
        self.class.render_show(ui: Rubino.ui)
      end

      # ONE full-config rendering for both surfaces (#187): this CLI verb and
      # the in-chat `/config show` — with secret-named keys masked, which the
      # clear-text dump never did (api_key landed verbatim in the scrollback).
      def self.render_show(ui:)
        ui.info(redact(Rubino.configuration.raw).to_yaml)
      end

      # Deep DISPLAY masking for config values (#187): a secret-named key's
      # value renders as *** (Util::SecretsMask — the same heuristic approval
      # prompts use), hashes/arrays are walked, and plain strings are scanned
      # for inline `Bearer …`-style credentials. Display-only — the file and
      # the live configuration keep the real values. Empty/nil values pass
      # through unmasked so a *** never fakes a value that isn't set.
      def self.redact(value, key: nil)
        case value
        when Hash  then value.to_h { |k, v| [k, redact(v, key: k)] }
        when Array then value.map { |v| redact(v, key: key) }
        when String
          value.empty? ? value : Util::SecretsMask.mask_value(value, key: key)
        else value
        end
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
