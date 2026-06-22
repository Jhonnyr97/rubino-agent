# frozen_string_literal: true

module Rubino
  module CLI
    # Health check command that verifies all system components are working.
    #
    # Doctor is a READ-ONLY diagnosis (#68): it must never create the home
    # directory or the database file while checking them — a never-setup
    # install is reported as "run `rubino setup`", not silently materialized
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

        # Web search backend (F8): only relevant when `tools.web` is on. Report
        # which backend a search would actually use (keyless DDG / Tavily /
        # SearXNG) and whether it looks usable, so a user who enabled web knows
        # search will work — never a required check (it's informational and must
        # not flip the exit status).
        check_websearch_backend if Rubino.configuration.tool_enabled?(:web)

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
          # A failed required check is a genuine FAILURE, not a soft caution: an
          # all-red `0/N` install must read as a hard ✗ (red), not a mild ⚠
          # (yellow) that understates a broken install (#557). `⚠` stays reserved
          # for the per-check warnings (pending migrations, unknown model, …).
          ui.error("#{passed}/#{total} required checks passed")
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
          ui.error("config file missing. Run `rubino setup`")
          return { name: "config", status: :fail }
        end

        # A structurally corrupt config (e.g. a scalar written over the `model`
        # section by an old `config set model foo`) must surface as a graceful
        # "corrupt config" diagnostic here, not as a raw TypeError backtrace from
        # a downstream check digging into the scalar (#259).
        error = config_corruption(loader)
        if error
          ui.error("config corrupt: #{error}. Fix #{loader.config_path} (or restore from a backup / re-run `rubino setup`)")
          return { name: "config", status: :fail }
        end

        ui.success("Config file exists: #{loader.config_path}")

        # LOAD-time schema validation (F8): a hand-edited config.yml with an
        # unknown key or a wrong-typed value is structurally fine (loads, digs)
        # but semantically wrong — the validator only ran at `config set` time,
        # so doctor used to show a flat green "✓ Config file exists" while a typo
        # silently degraded behaviour at runtime. Surface each issue as a WARNING
        # here (non-fatal — config still loads); the check stays :ok so existing
        # gates aren't tripped by a soft warning.
        config_issues(loader).each { |msg| ui.warning("config: #{msg}") }

        { name: "config", status: :ok }
      end

      # Load-time config-validation warnings (unknown key / wrong type), or [].
      # Best-effort: a probe hiccup must never crash doctor.
      def config_issues(loader)
        Config::Validator.warnings(loader.raw_config)
      rescue StandardError
        []
      end

      # Returns a human-readable reason the config is unusable, or nil when it
      # loads cleanly. A corrupt config makes Configuration#dig raise TypeError
      # (digging into a scalar where a section is expected) — catch it once here
      # so doctor can report it instead of crashing.
      def config_corruption(loader)
        loader.load
        config = Config::Configuration.new
        config.dig("model", "default")
        config.dig("model", "provider")
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
          ui.error("database not initialized: #{Rubino.database.db_path}. Run `rubino setup`")
          return { name: "database", status: :fail }
        end

        # A corrupt-but-present DB is its own diagnosis (#359): report it as
        # "corrupt" pointing at `rubino setup` (which quarantines + recreates),
        # NOT the vague "database not accessible" — and NEVER by letting the raw
        # SQLite3::CorruptException (with its stray `PRAGMA journal_mode=WAL`
        # fragment) leak through the StandardError rescue below into user output.
        if Rubino.database.corrupt?
          ui.error("database is corrupt (malformed image): #{Rubino.database.db_path}. " \
                   "Run `rubino setup` to quarantine it and recreate a fresh database")
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
        # Last-resort guard: still strip a corruption backtrace to the clean
        # diagnostic if it somehow reaches here (#359), so the raw exception
        # class + PRAGMA fragment never reach the user.
        if Rubino.database.corruption_error?(e)
          ui.error("database is corrupt (malformed image): #{Rubino.database.db_path}. " \
                   "Run `rubino setup` to quarantine it and recreate a fresh database")
        else
          ui.error("database error: #{e.message}")
        end
        { name: "database", status: :fail }
      end

      def check_migrations
        ui = Rubino.ui
        unless database_on_disk?
          ui.error("migrations not run — no database. Run `rubino setup`")
          return { name: "migrations", status: :fail }
        end

        # Skip the pending-migrations probe on a corrupt DB (#359): `pending?`
        # connects and runs `PRAGMA journal_mode=WAL`, which throws
        # SQLite3::CorruptException — the old `rescue` then printed that raw
        # exception (class name + the stray PRAGMA fragment) as the "migration
        # check failed" reason. check_database already reports the corruption
        # with the actionable fix; degrade cleanly here without re-leaking it.
        if Rubino.database.corrupt?
          ui.error("migration check skipped — database corrupt (run `rubino setup`)")
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
        # Final guard so a corruption backtrace (raw class + PRAGMA fragment)
        # never reaches user output even if it surfaces here (#359).
        if Rubino.database.corruption_error?(e)
          ui.error("migration check skipped — database corrupt (run `rubino setup`)")
        elsif e.message.to_s.include?("More than 1 row in migrator table")
          ui.error("migrator table has duplicate version rows (interrupted/raced migration). " \
                   "Run `rubino setup` to repair it")
        else
          ui.error("migration check failed: #{e.message}")
        end
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
          ui.error("home directory missing: #{home}. Run `rubino setup`")
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
          # Honest copy (#541): doctor checks that a key is PRESENT for the
          # configured provider, NOT that it actually authenticates — no live
          # auth probe is made (offline/rate-limit safe, matches the industry
          # norm). "configured" read as "validated", so a bogus pasted key got a
          # false green and only broke on the first real turn. Say "present" and
          # name the verify step so the user knows the green means "found", not
          # "works".
          ui.success("API key present (#{provider}) — not verified; first prompt confirms it")
          { name: "provider_keys", status: :ok }
        else
          # A missing key for the CONFIGURED provider is a hard ✗, not a soft ⚠
          # (#327): it is REQUIRED for any model call, so the agent can't work
          # without it. The warning glyph understated a broken install.
          ui.error("No credentials found for provider '#{provider}'. Set its API key (run `rubino setup`)")
          { name: "provider_keys", status: :fail }
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
        model = Rubino.configuration.dig("model", "default")

        if model.nil? || model.empty?
          ui.error("no model configured")
          return { name: "model", status: :fail }
        end

        # Honest pre-setup copy (#546): a non-empty `model.default` is NOT a
        # working model. A never-setup install carries a seeded placeholder under
        # an assume-exists provider, so `model` is present and the registry/
        # compatible branch below would print a green "Model configured: …" that
        # contradicts the real state — nothing is configured yet. With NO usable
        # credential the model can't be called, so say so and point at setup (a
        # warning, not a green success). Mirrors the #541 present-vs-verified
        # honesty in check_provider_keys; the credential verdict is scored there,
        # so this stays a non-blocking :warn rather than double-counting a :fail.
        unless model_usable?
          ui.warning("Model '#{model}' set, but no usable credential yet — run `rubino setup`")
          return { name: "model", status: :warn }
        end

        # Validate the model actually EXISTS, not just that a non-empty string is
        # present (#327): a typo'd `model.default` used to pass doctor and only
        # fail at the first model call with a 4xx. A custom/assume-exists provider
        # (MiniMax anthropic_compatible, an openai_compatible gateway) passes
        # arbitrary ids through deliberately, so its model is reported :ok without
        # a registry lookup. For a registry-backed provider, an id the catalog
        # doesn't know is a :warn — likely a typo — without blocking the score.
        if assume_exists_provider? || model_in_catalog?(model)
          ui.success("Model configured: #{model}")
          { name: "model", status: :ok }
        else
          ui.warning("Model '#{model}' is not in the known catalog for this provider (possible typo)")
          { name: "model", status: :warn }
        end
      rescue TypeError => e
        # `model.default` can't be read when the `model` section was clobbered
        # with a scalar — fail gracefully (check_config already explained why).
        ui.error("model check skipped — config corrupt: #{e.message}")
        { name: "model", status: :fail }
      end

      # True when the configured model has a usable credential — the same
      # source-of-truth check_provider_keys scores (#546). Used here so the model
      # line stays honest pre-setup: no usable credential ⇒ don't print a green
      # "Model configured". Any resolution hiccup degrades to "not usable" so a
      # broken/unconfigured install can never earn a false green.
      def model_usable?
        LLM::CredentialCheck.usable?
      rescue StandardError
        false
      end

      # True when the configured provider deliberately accepts arbitrary model
      # ids (a custom anthropic_compatible / openai_compatible backend, or an
      # explicit assume_model_exists gateway), so a registry lookup would report
      # a false "unknown model". The "fake" dev provider is treated the same.
      def assume_exists_provider?
        provider = LLM::CredentialCheck.resolved_provider
        return true if provider == "fake"

        cfg = Rubino.configuration.provider_config(provider)
        cfg["anthropic_compatible"] == true ||
          cfg["openai_compatible"] == true ||
          cfg["assume_model_exists"] == true
      rescue StandardError
        # Any resolution hiccup: don't manufacture a false "unknown model" — let
        # the model be reported present rather than risk a spurious warning.
        true
      end

      # True when the model id resolves in ruby_llm's registry. Any registry
      # hiccup is treated as "known" so a cosmetic check never blocks doctor.
      def model_in_catalog?(model)
        require "ruby_llm"
        !RubyLLM.models.find(model.to_s).nil?
      rescue RubyLLM::ModelNotFoundError
        false
      rescue StandardError
        true
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

      # Non-scoring report of the web-search backend (F8). With `tools.web` on,
      # the websearch tool picks a backend by env, in this priority: Tavily
      # (TAVILY_API_KEY) → SearXNG (SEARXNG_URL) → keyless DuckDuckGo Instant
      # Answer. Tell the user WHICH one a search will use and whether it looks
      # reachable, so an enabled-but-unusable backend is visible here instead of
      # surfacing as an empty "search unavailable" mid-conversation. Mirrors the
      # MCP/doc-converter "Optional (…)" sections: informational, never scored,
      # and any hiccup degrades to a warning so it can't break doctor.
      def check_websearch_backend
        ui = Rubino.ui
        ui.blank_line
        ui.info("Optional (web search backend, tools.web is on):")

        if present_env?("TAVILY_API_KEY")
          ui.success("Web search backend: Tavily (TAVILY_API_KEY configured)")
        elsif present_env?("SEARXNG_URL")
          ui.success("Web search backend: SearXNG (SEARXNG_URL=#{ENV.fetch("SEARXNG_URL", nil)})")
        elsif ddg_resolvable?
          ui.success("Web search backend: DuckDuckGo (keyless; reachable). " \
                     "Set TAVILY_API_KEY or SEARXNG_URL for full web-index results")
        else
          ui.warning("Web search may not work: no TAVILY_API_KEY / SEARXNG_URL and " \
                     "DuckDuckGo (api.duckduckgo.com) is unreachable. Set TAVILY_API_KEY " \
                     "or SEARXNG_URL, or disable with `rubino config set tools.web false`")
        end
      rescue StandardError => e
        ui.warning("Web search backend check failed: #{e.message}")
      end

      def present_env?(var)
        val = ENV.fetch(var, nil)
        !val.nil? && !val.to_s.strip.empty?
      end

      # Best-effort DNS resolution of the keyless DDG Instant-Answer host — the
      # same cheap reachability probe the tool registry uses to gate the tool,
      # so doctor's verdict matches whether the tool is actually exposed. Any
      # resolver error means "not reachable" (the caller then warns).
      def ddg_resolvable?
        require "resolv"
        !Resolv.getaddress("api.duckduckgo.com").nil?
      rescue StandardError
        false
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
