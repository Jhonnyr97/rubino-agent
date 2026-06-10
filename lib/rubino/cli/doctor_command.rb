# frozen_string_literal: true

module Rubino
  module CLI
    # Health check command that verifies all system components are working.
    #
    # Doctor is a READ-ONLY diagnosis (#68): it must never create the home
    # directory or the database file while checking them — a never-setup
    # install is reported as "run 'rubino setup'", not silently materialized
    # at the umask's permissions and then declared healthy.
    #
    # Exit status (#67): non-zero when one or more required checks did not
    # pass, so CI/scripts can gate on `rubino doctor`.
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

        # MCP servers are optional integrations (#90): report each configured
        # server's reachability best-effort, but never let a down MCP server
        # fail doctor — it is informational, not a required check, so non-MCP
        # users (and MCP users with a flaky server) still exit 0.
        check_mcp_servers if MCP.enabled?

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
          # Scripts/CI gate on doctor: a failed required check must be a
          # non-zero exit, not a green 0 under a red report (#67).
          exit(1)
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
          ui.error("config file missing. Run 'rubino setup'")
          { name: "config", status: :fail }
        end
      end

      def check_database
        ui = Rubino.ui
        unless database_on_disk?
          ui.error("database not initialized: #{Rubino.database.db_path}. Run 'rubino setup'")
          return { name: "database", status: :fail }
        end

        if Rubino.database.healthy?
          ui.success("Database accessible: #{Rubino.database.db_path}")
          { name: "database", status: :ok }
        else
          ui.error("database not accessible")
          { name: "database", status: :fail }
        end
      rescue StandardError => e
        ui.error("database error: #{e.message}")
        { name: "database", status: :fail }
      end

      def check_migrations
        ui = Rubino.ui
        unless database_on_disk?
          ui.error("migrations not run — no database. Run 'rubino setup'")
          return { name: "migrations", status: :fail }
        end

        migrator = Database::Migrator.new(Rubino.database)

        if migrator.pending?
          ui.warning("Pending migrations exist")
          { name: "migrations", status: :warn }
        else
          ui.success("Migrations up to date")
          { name: "migrations", status: :ok }
        end
      rescue StandardError => e
        ui.error("migration check failed: #{e.message}")
        { name: "migrations", status: :fail }
      end

      # Read-only guard for the two DB checks (#68): SQLite lazily CREATES the
      # file (and its parent directory) on the first connection, so probing a
      # never-setup home with `SELECT 1` would mutate it — and doctor would then
      # report the empty, unmigrated database it just created as "accessible".
      # A missing file is an uninitialized install: report it without touching
      # the disk.
      def database_on_disk?
        db = Rubino.database
        db.memory? || File.exist?(db.db_path)
      end

      def check_directories
        ui = Rubino.ui
        home = Rubino.home_path

        if File.directory?(home)
          ui.success("Home directory exists: #{home}")
          { name: "directories", status: :ok }
        else
          ui.error("home directory missing: #{home}. Run 'rubino setup'")
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
          ui.error("no model configured")
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

      # Best-effort MCP reachability report (#90). Starts each configured
      # server, health-checks it, and stops everything again — doctor stays
      # read-only and leaves no child processes behind. Deliberately NOT part
      # of the required score: a server that fails to start already warned via
      # Manager#start_server, a started-but-dead one warns here, and neither
      # flips the exit status. Any unexpected error degrades to a warning so
      # the MCP section can never break doctor itself.
      def check_mcp_servers
        ui = Rubino.ui
        ui.blank_line
        ui.info("Optional (MCP servers, experimental):")

        servers = Rubino.configuration.dig("mcp", "servers") || {}
        manager = MCP::Manager.new
        servers.each { |name, server_config| manager.start_server(name, server_config) }

        manager.health_check.each do |status|
          if status[:alive]
            ui.success("MCP server '#{status[:name]}' reachable")
          else
            ui.warning("MCP server '#{status[:name]}' not reachable")
          end
        end
        manager.stop_all!
      rescue StandardError => e
        ui.warning("MCP check failed: #{e.message}")
      end
    end
  end
end
