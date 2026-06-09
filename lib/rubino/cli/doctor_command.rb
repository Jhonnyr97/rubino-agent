# frozen_string_literal: true

module Rubino
  module CLI
    # Health check command that verifies all system components are working.
    class DoctorCommand
      def execute
        ui = Rubino.ui
        ui.info("Running system diagnostics...")
        ui.blank_line

        # Required checks score the headline verdict — these are what a CLI user
        # needs for a working install. The encryption key is SERVER-ONLY (JSON
        # API / OAuth) and a CLI-only user never touches it, so it lives in a
        # separate optional section and is NOT counted against the score (#143):
        # a healthy default install reports all-green.
        required = [
          check_config,
          check_database,
          check_migrations,
          check_directories,
          check_provider_keys,
          check_model_configured
        ]

        ui.blank_line
        ui.info("Optional (API/OAuth server):")
        optional = [check_encryption_key]

        ui.blank_line
        passed = required.count { |c| c[:status] == :ok }
        total = required.size
        optional_unconfigured = optional.count { |c| c[:status] != :ok }

        if passed == total
          ui.success("All #{total} checks passed!")
          if optional_unconfigured.positive?
            ui.info("(#{optional_unconfigured} optional server check#{"s" if optional_unconfigured != 1} not configured — only needed to run the API/OAuth server)")
          end
        else
          ui.warning("#{passed}/#{total} required checks passed")
        end
      end

      private

      def check_config
        ui = Rubino.ui
        loader = Config::Loader.new

        if loader.config_exists?
          ui.success("Config file exists: #{loader.config_path}")
          { name: "config", status: :ok }
        else
          ui.error("Config file missing. Run 'rubino setup'")
          { name: "config", status: :fail }
        end
      end

      def check_database
        ui = Rubino.ui

        if Rubino.database.healthy?
          ui.success("Database accessible: #{Rubino.database.db_path}")
          { name: "database", status: :ok }
        else
          ui.error("Database not accessible")
          { name: "database", status: :fail }
        end
      rescue StandardError => e
        ui.error("Database error: #{e.message}")
        { name: "database", status: :fail }
      end

      def check_migrations
        ui = Rubino.ui
        migrator = Database::Migrator.new(Rubino.database)

        if migrator.pending?
          ui.warning("Pending migrations exist")
          { name: "migrations", status: :warn }
        else
          ui.success("Migrations up to date")
          { name: "migrations", status: :ok }
        end
      rescue StandardError => e
        ui.error("Migration check failed: #{e.message}")
        { name: "migrations", status: :fail }
      end

      def check_directories
        ui = Rubino.ui
        home = Rubino.home_path

        if File.directory?(home)
          ui.success("Home directory exists: #{home}")
          { name: "directories", status: :ok }
        else
          ui.error("Home directory missing: #{home}")
          { name: "directories", status: :fail }
        end
      end

      # Verifies the credentials for the ACTUALLY configured provider resolve —
      # not a hardcoded ENV allowlist. A tenant on an openai_compatible backend
      # (ollama, vllm, a hosted gateway, …) configures its key under
      # providers.<name>.api_key in config.yml; the old hardcoded check ignored
      # that and warned "No API keys found" on a correctly-configured tenant.
      def check_provider_keys
        ui = Rubino.ui
        provider = LLM::CredentialCheck.resolved_provider

        if LLM::CredentialCheck.usable?
          ui.success("API key configured (#{provider})")
          { name: "provider_keys", status: :ok }
        else
          ui.warning("No credentials found for provider '#{provider}'")
          { name: "provider_keys", status: :warn }
        end
      end

      def check_model_configured
        ui = Rubino.ui
        model = Rubino.configuration.model_default

        if model && !model.empty?
          ui.success("Model configured: #{model}")
          { name: "model", status: :ok }
        else
          ui.error("No model configured")
          { name: "model", status: :fail }
        end
      end

      # Verifies the OAuth-token encryption key is present and well-formed
      # WITHOUT crashing doctor itself: server boot uses Boot::EncryptionKey
      # for the hard fail-fast path, but doctor must keep running so the
      # operator sees every other check that did pass.
      #
      # The key is only needed by the JSON API / OAuth (encrypted-token) path;
      # a CLI-only user never touches it. So a MISSING key is a :warn scoped to
      # that path, not a scary red :fail that makes a healthy CLI install look
      # broken (F4). A key that IS set but malformed is still a real :fail —
      # that's a misconfiguration the operator must fix before the server boots.
      def check_encryption_key
        ui = Rubino.ui
        OAuth::TokenEncryptor.from_env
        ui.success("Encryption key configured")
        { name: "encryption_key", status: :ok }
      rescue OAuth::TokenEncryptor::KeyMissingError
        ui.warning("RUBINO_ENCRYPTION_KEY not set (only needed for the API/OAuth server)")
        { name: "encryption_key", status: :warn }
      rescue ArgumentError => e
        ui.error("RUBINO_ENCRYPTION_KEY invalid: #{e.message}")
        { name: "encryption_key", status: :fail }
      end
    end
  end
end
