# frozen_string_literal: true

require "fileutils"

module Rubino
  module CLI
    # Handles initial setup: creates config directory, default config,
    # initializes the database, and runs migrations.
    class SetupCommand
      def execute
        ui = Rubino.ui

        ui.info("Setting up rubino...")
        ui.blank_line

        # Create home directory (0700 — only the owner sees stored secrets)
        home = Rubino.home_path
        FileUtils.mkdir_p(home)
        File.chmod(0o700, home)
        ui.success("Home directory: #{home}")

        # Create subdirectories
        Rubino.ensure_directories!
        ui.success("Subdirectories created")

        # Create config file if it doesn't exist
        loader = Config::Loader.new
        if loader.config_exists?
          ui.warning("Config already exists: #{loader.config_path}")
        else
          loader.create_default_config!
          File.chmod(0o600, loader.config_path)
          ui.success("Config created: #{loader.config_path}")
        end

        # Create .env template if it doesn't exist (0600 — contains api keys)
        env_path = File.join(home, ".env")
        unless File.exist?(env_path)
          File.write(env_path, env_template)
          File.chmod(0o600, env_path)
          ui.success("Env template created: #{env_path}")
        end

        # Initialize database
        ui.status("Initializing database...")
        connection = Rubino.database
        migrator = Database::Migrator.new(connection)
        migrator.migrate!
        ui.success("Database initialized: #{connection.db_path}")

        # First-run onboarding: if no usable key is configured yet AND we're on
        # a real TTY, guide the user to a working model (provider/model/key)
        # right here so `setup` ends in a usable config — not a dead-end that
        # still needs hand-editing config.yml (#93). Non-interactive setup keeps
        # the old behaviour (files created, no prompts).
        maybe_run_onboarding(ui)

        ui.blank_line
        ui.success("Setup complete! Run 'rubino doctor' to verify.")
      end

      private

      def maybe_run_onboarding(ui)
        return unless interactive?
        return if LLM::CredentialCheck.usable?

        OnboardingWizard.new(ui: ui).run
      end

      def interactive?
        $stdin.tty? && $stdout.tty?
      rescue StandardError
        false
      end

      def env_template
        <<~ENV
          # Rubino API Keys
          # Add your API keys here. Do NOT commit this file.
          # `rubino setup` (on a terminal) can fill one in for you.

          # MiniMax (recommended default — Anthropic-compatible)
          # MINIMAX_API_KEY=...

          # OpenAI
          # OPENAI_API_KEY=sk-...

          # Anthropic
          # ANTHROPIC_API_KEY=sk-ant-...

          # Google
          # GEMINI_API_KEY=...
        ENV
      end
    end
  end
end
