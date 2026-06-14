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
        # and subdirectories. ensure_directories! owns the mkdir + chmod so
        # every entry point that materializes the home agrees on 0700 (#65).
        home = Rubino.home_path
        Rubino.ensure_directories!
        ui.success("Home directory: #{home}")
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

        # Initialize database. `setup` is the documented remedy for a broken
        # install, so it must SELF-HEAL a corrupt/truncated DB instead of
        # crashing with a raw SQLite3::CorruptException backtrace (HIGH-2): if
        # the file is present but unopenable, quarantine it aside (preserving the
        # bytes for forensics) and recreate a fresh one.
        ui.status("Initializing database...")
        connection = recover_corrupt_database(ui)
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
        # Tell the truth about the end state (#31). A green "Setup complete!" is
        # only honest when a usable credential is actually configured — printing
        # it after a skipped/abandoned onboarding (no provider, no key) directly
        # contradicts the state. Re-check the credential after onboarding so the
        # final line reflects reality on both the interactive and the
        # non-interactive (files-only) paths.
        if LLM::CredentialCheck.usable?
          ui.success("Setup complete! Run 'rubino doctor' to verify.")
        else
          ui.warning("Setup files created, but no model is configured yet.")
          ui.status("Run 'rubino setup' again or add an API key, then 'rubino doctor' to verify.")
        end
      end

      private

      # Detect a corrupt on-disk DB and recover it. Returns a usable connection:
      # the existing one when the file is healthy/absent, or a fresh connection
      # after the malformed file has been renamed to `<name>.corrupt-<ts>`.
      def recover_corrupt_database(ui)
        connection = Rubino.database
        return connection unless connection.corrupt?

        moved = connection.quarantine!
        ui.warning("Existing database was corrupt (malformed image).")
        ui.status("Quarantined to: #{moved}") if moved
        # Drop the memoized connection so the next access opens a brand-new file.
        Rubino.reset_database!
        Rubino.database
      end

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
