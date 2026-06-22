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
        # `setup` is the documented repair path. The schema is a single,
        # fully-idempotent baseline migration (`create_table?` / `IF NOT EXISTS`
        # throughout) applied under the cross-process flock, so this is safe to
        # run on a fresh, partial, or already-migrated home alike — a healthy DB
        # just no-ops, a partial one finishes, and a re-run never collides.
        migrator.migrate!(lock_path: Rubino.migration_lock_path)
        ui.success("Database initialized: #{connection.db_path}")

        # First-run onboarding: if no usable key is configured yet AND we're on
        # a real TTY, guide the user to a working model (provider/model/key)
        # right here so `setup` ends in a usable config — not a dead-end that
        # still needs hand-editing config.yml (#93). Non-interactive setup keeps
        # the old behaviour (files created, no prompts).
        maybe_run_onboarding(ui)

        # Non-interactive provider auto-detect (#392a): a headless `setup` can't
        # prompt, so the seeded default (openai/gpt-4.1 → OPENAI_API_KEY) is a
        # dead end when the only key in the env is, say, MINIMAX_API_KEY — doctor
        # then fails "No credentials found for provider 'openai'". When EXACTLY
        # ONE provider's key is present in the env, point model.provider /
        # model.default (and any required providers.<name> block) at it so a
        # CI/container `setup` lands on a usable config. Ambiguous (>1 key) or
        # none keeps the seeded default untouched.
        maybe_autodetect_provider(ui)

        # Offer command + file output compression (test/build/lint dumps and
        # whole-file Ruby reads) — routed through the single ContentRouter seam.
        # Interactive only, idempotent (skips when already on), recommended
        # default. The shipped config keeps it off so existing and headless
        # installs are untouched; this is the "activate from setup" path. The
        # original is always recoverable via the appended read pointer.
        maybe_offer_log_compression(ui)

        ui.blank_line
        # Tell the truth about the end state (#31). A green "Setup complete!" is
        # only honest when a usable credential is actually configured — printing
        # it after a skipped/abandoned onboarding (no provider, no key) directly
        # contradicts the state. Re-check the credential after onboarding so the
        # final line reflects reality on both the interactive and the
        # non-interactive (files-only) paths.
        if LLM::CredentialCheck.usable?
          ui.success("Setup complete! Run 'rubino doctor' to verify.")
        elsif (model = Rubino.configuration.dig("model", "default").to_s).empty?
          ui.warning("Setup files created, but no model is configured yet.")
          ui.status("Run 'rubino setup' again or add an API key, then 'rubino doctor' to verify.")
        else
          # A model IS configured (#31) — what's missing is its CREDENTIAL (only a
          # different provider's key is present), so the old "no model configured"
          # copy was wrong. Name the model and point at the guided setup.
          provider = LLM::CredentialCheck.resolved_provider
          ui.warning("Setup files created, but the API key for #{model} (provider '#{provider}') is missing.")
          ui.status("Run 'rubino setup' to add it, then 'rubino doctor' to verify.")
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

      # Interactive "activate from setup" step for command + file output
      # compression. Skipped on headless setup (no prompt) and when the master
      # flag is already on, so a re-run never nags. A bare Enter accepts
      # (recommended on). Writing the unified `enabled` flag is the ONLY
      # persistence; a decline leaves the seeded default (off). The per-type
      # `logs.enabled` sub-flag is turned on too so the log channel is active.
      def maybe_offer_log_compression(ui)
        return unless interactive?
        return if Rubino.configuration.tool_output_compression_enabled?

        ui.blank_line
        ui.info("Command + file output compression")
        ui.status("  Compresses test/build/shell output AND whole-file Ruby reads before they reach")
        ui.status("  the model — keeps every failure + summary (and code signatures), drops passing")
        ui.status("  noise. ~97% fewer tokens on a test suite. The full output stays one `read` away.")
        return unless prompt_enable?("Enable it?")

        loader = Config::Loader.new
        loader.create_default_config! unless loader.config_exists?
        writer = Config::Writer.new(config_path: loader.config_path)
        writer.set("tool_output_compression.enabled", true)
        writer.set("tool_output_compression.logs.enabled", true)
        Rubino.reload_configuration!
        ui.success("Command + file output compression enabled.")
      rescue StandardError => e
        # A convenience toggle must never fail setup.
        Rubino.logger.warn(event: "setup.log_compression_offer_failed",
                           error: e.class.name, message: e.message)
        nil
      end

      # Y/n prompt with a recommended-yes default (bare Enter ⇒ true). Only an
      # explicit n/no declines; EOF (piped) declines too so non-TTY never blocks.
      def prompt_enable?(question)
        $stdout.print "#{question} [Y/n]: "
        $stdout.flush
        ans = $stdin.gets
        return false if ans.nil?

        !%w[n no].include?(ans.strip.downcase)
      rescue StandardError
        false
      end

      # Non-interactive provider auto-detect (#392a). Only the headless path
      # (no TTY) reaches here — interactive setup uses the wizard, which already
      # resolves provider/key explicitly. Picks the provider whose .env key is
      # the single one present in the environment and rewrites the model
      # provider/default + its required config block to match, so a fresh
      # container `setup` that only has MINIMAX_API_KEY doesn't default to
      # OpenAI and then fail doctor.
      def maybe_autodetect_provider(ui)
        return if interactive?

        choice = single_env_provider
        return unless choice
        # Already pointed at this provider (e.g. config carried over): nothing
        # to rewrite, and don't churn the file or its line on every re-run.
        return if Rubino.configuration.dig("model", "provider") == choice[:provider]

        # Non-destructive re-run (F9): a re-run of `setup` over an EXISTING
        # config must never silently clobber a model the user deliberately
        # picked. Auto-detect only fills the SEEDED default — if model.default
        # or model.provider has already been customized away from the seed, the
        # headless path can't prompt "change X → Y?", so it PRESERVES the pick
        # and just tells the user how to switch. (Industry: idempotent setup
        # fills missing fields, never overwrites a set one.)
        if model_customized?
          cfg = Rubino.configuration
          ui.status("Detected #{choice[:env_var]}, but keeping your configured model " \
                    "#{cfg.dig("model", "default")} (#{cfg.dig("model", "provider")}). " \
                    "Run `rubino config set model.provider #{choice[:provider]}` to switch.")
          return
        end

        persist_autodetected!(choice)
        Rubino.reload_configuration!
        ui.success("Detected #{choice[:env_var]} — defaulting to #{choice[:provider]}/#{choice[:model]}.")
      rescue StandardError => e
        # Auto-detect is a convenience; a write hiccup must never fail setup.
        Rubino.logger.warn(event: "setup.autodetect_failed", error: e.class.name, message: e.message)
        nil
      end

      # True when the user has moved model.default / model.provider OFF the
      # seeded defaults (openai/gpt-4.1, provider "auto") — i.e. there is a
      # deliberate pick the headless auto-detect must not silently overwrite.
      def model_customized?
        cfg = Rubino.configuration
        seed = Config::Defaults::MODULE_DEFAULTS["model"] || {}
        cfg.dig("model", "default") != seed["default"] || cfg.dig("model", "provider") != seed["provider"]
      rescue StandardError
        # If we can't tell, err on the side of PRESERVING the user's config.
        true
      end

      # The one provider catalog entry whose env key is present in ENV, or nil
      # when none or MORE THAN ONE is set (ambiguous — keep the seeded default).
      def single_env_provider
        present = OnboardingWizard::PROVIDERS.select do |p|
          val = ENV.fetch(p[:env_var], nil)
          !val.nil? && !val.empty?
        end
        # Dedup by env_var: the gateway entry reuses OPENAI_API_KEY, so an
        # OpenAI key would otherwise look "ambiguous". Collapse to distinct keys
        # and only auto-detect when a single distinct provider key is present.
        present.uniq! { |p| p[:env_var] }
        present.one? ? present.first : nil
      end

      # Writes the detected provider's model.provider / model.default and its
      # required providers.<name> block (the same blocks the wizard persists).
      # Does NOT touch .env — the key is already in the environment.
      def persist_autodetected!(choice)
        loader = Config::Loader.new
        loader.create_default_config! unless loader.config_exists?
        writer = Config::Writer.new(config_path: loader.config_path)
        writer.set("model.default", choice[:model])
        writer.set("model.provider", choice[:provider])
        choice[:config].each do |k, v|
          next if v.nil? || (v.respond_to?(:empty?) && v.empty?)

          writer.set("providers.#{choice[:provider]}.#{k}", v)
        end
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

          # OpenAI (GPT — recommended default, matches the seeded model
          # openai/gpt-4.1)
          # OPENAI_API_KEY=sk-...

          # MiniMax (Anthropic-compatible)
          # MINIMAX_API_KEY=...

          # Anthropic
          # ANTHROPIC_API_KEY=sk-ant-...

          # Google
          # GEMINI_API_KEY=...
        ENV
      end
    end
  end
end
