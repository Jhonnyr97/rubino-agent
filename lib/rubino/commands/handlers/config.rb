# frozen_string_literal: true

module Rubino
  module Commands
    module Handlers
      # The `/config` in-chat read/set surface, extracted from Commands::Executor
      # (batch B) — over the SAME effective config (file merged over defaults)
      # the `rubino config` CLI verbs use (#187), so checking `memory.backend` no
      # longer means quitting the REPL. Rendering is shared with the CLI
      # (CLI::ConfigCommand.render_get / .render_show), so secret-named keys are
      # masked identically on both surfaces.
      #
      #   /config                  → config file path + usage hint
      #   /config show             → the full merged config, secrets masked
      #   /config path             → the config file path
      #   /config <key>            → get (dot-notation; `get <key>` also works)
      #   /config <key> <value>    → set: the same Config::Writer write-through
      #                              /reasoning uses (`set <key> <value>` too)
      class Config
        def initialize(ui:)
          @ui = ui
        end

        def handle_config(arguments)
          tokens = arguments.to_s.strip.split(/\s+/)
          case tokens.first
          when nil    then show_config_summary
          when "show" then CLI::ConfigCommand.render_show(ui: @ui)
          when "path" then @ui.info(Rubino::Config::Loader.new.config_path)
          when "get"  then config_get(tokens[1])
          when "set"  then config_set(tokens[1], tokens[2..])
          else
            tokens.length == 1 ? config_get(tokens.first) : config_set(tokens.first, tokens[1..])
          end
        end

        private

        def show_config_summary
          @ui.info("config  #{Rubino::Config::Loader.new.config_path}")
          @ui.info("/config show   ·   /config <key>   ·   /config <key> <value>")
        end

        def config_get(key)
          if key.to_s.empty?
            @ui.info("Usage: /config get <key>  (dot-notation, e.g. memory.backend)")
            return
          end

          # render_get returns false on a miss and no longer prints the
          # not-found notice itself (P2-H2: the CLI verb routes its miss to
          # stderr instead). The REPL keeps the friendly inline warning here.
          @ui.warning("Key '#{key}' not found") unless CLI::ConfigCommand.render_get(key, ui: @ui)
        end

        # Write-through + live update, the same pair /reasoning and /think run
        # (#131): the file write makes the change survive the session; the
        # in-memory set applies it to config reads from the next turn. The echo
        # is masked like `config show` so a freshly-set api_key never lands in
        # the scrollback. Consumers that memoize their config (e.g. the memory
        # backend) still need a restart — same caveat as the CLI verb.
        def config_set(key, value_tokens)
          value = Array(value_tokens).join(" ")
          if key.to_s.empty? || value.empty?
            @ui.info("Usage: /config set <key> <value>")
            return
          end

          writer = Rubino::Config::Writer.new(config_path: Rubino::Config::Loader.new.config_path)
          writer.set(key, value)
          coerced = writer.get(key)
          apply_config_live(key, coerced)
          @ui.success("#{key} = #{CLI::ConfigCommand.redact(coerced, key: key.split(".").last)}   " \
                      "(persisted; applies from the next turn — memoizing consumers need a restart)")
        rescue Rubino::ConfigurationError => e
          @ui.error(e.message)
        end

        # Mirrors the Writer's (already validated + coerced) value onto the live
        # configuration. Best-effort: the merged in-memory tree can disagree
        # with the file's shape (a default-valued scalar where the file grew a
        # section), in which case the persisted value still applies on restart.
        def apply_config_live(key, value)
          Rubino.configuration.set(*key.split("."), value)
        rescue StandardError
          @ui.warning("#{key} persisted to config.yml but could not be applied live — restart to pick it up")
        end
      end
    end
  end
end
