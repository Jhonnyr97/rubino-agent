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

        # Document converters are an optional in-process capability (#6): report
        # which CORE formats can be read in-process (their optional gem is
        # loadable), but never let an absent gem fail doctor — pure-ruby formats
        # always work and missing extraction gems only narrow the supported set.
        check_document_converters

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

        unless loader.config_exists?
          ui.error("config file missing. Run 'rubino setup'")
          return { name: "config", status: :fail }
        end

        # A structurally corrupt config (e.g. a scalar written over the `model`
        # section by an old `config set model foo`) must surface as a graceful
        # "corrupt config" diagnostic here, not as a raw TypeError backtrace from
        # a downstream check digging into the scalar (#259).
        error = config_corruption(loader)
        if error
          ui.error("config corrupt: #{error}. Fix #{loader.config_path} (or restore from a backup / re-run 'rubino setup')")
          return { name: "config", status: :fail }
        end

        ui.success("Config file exists: #{loader.config_path}")
        { name: "config", status: :ok }
      end

      # Returns a human-readable reason the config is unusable, or nil when it
      # loads cleanly. A corrupt config makes Configuration#dig raise TypeError
      # (digging into a scalar where a section is expected) — catch it once here
      # so doctor can report it instead of crashing.
      def config_corruption(loader)
        loader.load
        config = Config::Configuration.new
        config.model_default
        config.model_provider
        nil
      rescue Config::ConfigError => e
        e.message
      rescue TypeError => e
        "a section was overwritten with a scalar value (#{e.message})"
      rescue StandardError => e
        "#{e.class}: #{e.message}"
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
      rescue TypeError => e
        # A corrupt config (a scalar over the `model`/`providers` section) makes
        # Configuration#dig raise here. check_config already reported the
        # corruption; this check just degrades to :fail without a backtrace (#259).
        ui.error("provider check skipped — config corrupt: #{e.message}")
        { name: "provider_keys", status: :fail }
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
      rescue TypeError => e
        # `model.default` can't be read when the `model` section was clobbered
        # with a scalar — fail gracefully (check_config already explained why).
        ui.error("model check skipped — config corrupt: #{e.message}")
        { name: "model", status: :fail }
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

      # Non-scoring report of the in-process document-conversion capability
      # (#6), mirroring the MCP "Optional (…)" pattern. Pure-ruby formats are
      # always green; a gem-backed format whose optional gem isn't installed is
      # a warning (never a fail), so a healthy default install never shows red
      # for a capability it can extend by installing an optional gem.
      def check_document_converters
        ui = Rubino.ui
        ui.blank_line
        ui.info("Optional (document converters, in-process via read_attachment):")

        Rubino::Documents::Registry.capabilities.each do |format, available|
          if available
            ui.success("#{format} supported")
          else
            ui.warning("#{format} not available (install its optional gem to enable)")
          end
        end
      rescue StandardError => e
        ui.warning("Document-converter check failed: #{e.message}")
      end
    end
  end
end
