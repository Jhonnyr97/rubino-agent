# frozen_string_literal: true

require "fileutils"

module Rubino
  module CLI
    # First-run onboarding (#93). A small, skippable interactive wizard that
    # takes a brand-new user from an empty home to a working model: pick a
    # provider/model, paste the key (written to .env, never echoed back), and
    # persist the matching model.default / model.provider / providers.<name>
    # block to config.yml. The catalog mirrors DOCS-BLUEPRINT models-and-keys.
    #
    # It is only invoked when no usable credential is configured AND we are on a
    # real TTY (ChatCommand#ensure_model_configured!); non-interactive contexts
    # get the actionable guidance instead. #run returns true on a completed
    # setup, false if the user skipped — the caller re-checks usability either
    # way, so a partial/declined run safely falls through to the guidance+exit.
    class OnboardingWizard
      # Each provider: the model.provider to write, a default model id, the .env
      # key var, and any providers.<name> config block to persist. Ordered so the
      # recommended default (MiniMax) comes first, matching the blueprint.
      PROVIDERS = [
        {
          key:      "minimax",
          label:    "MiniMax (recommended default — Anthropic-compatible)",
          provider: "minimax",
          model:    "MiniMax-M2.7",
          env_var:  "MINIMAX_API_KEY",
          config:   {
            "anthropic_compatible" => true,
            "base_url"             => "https://api.minimax.io/anthropic",
            "api_key"              => "${MINIMAX_API_KEY}"
          }
        },
        {
          key:      "openai",
          label:    "OpenAI (GPT)",
          provider: "openai",
          model:    "gpt-4.1",
          env_var:  "OPENAI_API_KEY",
          config:   {}
        },
        {
          key:      "anthropic",
          label:    "Anthropic (Claude)",
          provider: "anthropic",
          model:    "claude-sonnet-4-5",
          env_var:  "ANTHROPIC_API_KEY",
          config:   {}
        },
        {
          key:      "gemini",
          label:    "Google (Gemini)",
          provider: "google",
          model:    "gemini-2.5-pro",
          env_var:  "GEMINI_API_KEY",
          config:   {}
        },
        {
          key:      "rubino-ui",
          label:    "rubino-ui proxy (OpenAI-compatible gateway)",
          provider: "rubino-ui",
          model:    "auto",
          env_var:  "OPENAI_API_KEY",
          config:   {
            "openai_compatible"   => true,
            "assume_model_exists" => true,
            "base_url"            => nil # filled in interactively
          }
        }
      ].freeze

      def initialize(ui: Rubino.ui, input: $stdin, output: $stdout)
        @ui     = ui
        @input  = input
        @output = output
      end

      # Drives the wizard. Returns true when a provider was configured, false
      # when the user skipped (empty/`s`/`skip` at the provider prompt).
      def run
        @ui.blank_line
        @ui.info("Welcome to rubino — let's get you connected to a model.")
        @ui.status("No API key is configured yet. Pick a provider (or press Enter to skip).")
        @ui.blank_line

        choice = ask_provider
        return false unless choice

        api_key = ask_api_key(choice)
        return false if api_key.nil? || api_key.empty?

        base_url = ask_base_url(choice)

        persist!(choice, api_key, base_url)
        Rubino.reload_configuration!

        @ui.blank_line
        @ui.success("Configured #{choice[:label]} with model #{choice[:model]}.")
        @ui.status("Saved to #{config_loader.config_path} and #{config_loader.env_path}.")
        @ui.blank_line
        true
      end

      private

      def ask_provider
        PROVIDERS.each_with_index do |p, i|
          @output.puts "  #{i + 1}) #{p[:label]}"
        end
        @output.print "Choose a provider [1-#{PROVIDERS.size}, Enter to skip]: "
        @output.flush
        raw = read_line
        return nil if raw.nil? || raw.strip.empty? || %w[s skip].include?(raw.strip.downcase)

        idx = raw.strip.to_i
        return PROVIDERS[idx - 1] if idx.between?(1, PROVIDERS.size)

        @ui.warning("Not a valid choice — skipping setup.")
        nil
      end

      def ask_api_key(choice)
        @output.print "Paste your #{choice[:env_var]} (input hidden; Enter to skip): "
        @output.flush
        read_secret.to_s.strip
      end

      # The proxy provider needs a base_url; everyone else uses the upstream
      # default, so we only ask when the catalog entry left base_url nil.
      def ask_base_url(choice)
        return nil unless choice[:config].key?("base_url") && choice[:config]["base_url"].nil?

        @output.print "Enter the gateway base URL (e.g. https://host/v1): "
        @output.flush
        read_line.to_s.strip
      end

      def persist!(choice, api_key, base_url)
        Rubino.ensure_directories!
        loader = config_loader
        # Seed config.yml from defaults the first time so the wizard's keys land
        # in a complete, hand-editable file rather than a 3-line stub.
        loader.create_default_config! unless loader.config_exists?

        writer = Config::Writer.new(config_path: loader.config_path)
        writer.set("model.default", choice[:model])
        writer.set("model.provider", choice[:provider])

        choice[:config].each do |k, v|
          value = (k == "base_url" && (v.nil? || v.empty?)) ? base_url : v
          next if value.nil?

          writer.set("providers.#{choice[:provider]}.#{k}", value)
        end

        write_env_key!(loader.env_path, choice[:env_var], api_key)
      end

      # Appends/updates KEY=value in .env (0600). Does not echo the value. An
      # existing line for the same key is replaced so re-running setup updates it.
      def write_env_key!(env_path, var, value)
        lines = File.exist?(env_path) ? File.readlines(env_path, chomp: true) : []
        lines.reject! { |l| l =~ /\A#{Regexp.escape(var)}=/ }
        lines << "#{var}=#{value}"
        File.write(env_path, lines.join("\n") + "\n")
        File.chmod(0o600, env_path)
        # Make the key visible to THIS process too, so the immediate usability
        # re-check and any subsequent model call in this run can see it.
        ENV[var] = value
      end

      def config_loader
        @config_loader ||= Config::Loader.new
      end

      def read_line
        @input.gets
      rescue StandardError
        nil
      end

      # Hidden input for the key. Falls back to a plain read when the terminal
      # can't toggle echo (piped input in tests).
      def read_secret
        if @input.respond_to?(:noecho) && @input.tty?
          begin
            secret = @input.noecho(&:gets)
            @output.puts
            return secret
          rescue StandardError
            # fall through to plain read
          end
        end
        read_line
      end
    end
  end
end
