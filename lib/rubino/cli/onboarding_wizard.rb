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
      # recommended default comes first and matches the seeded config default
      # (config/defaults.rb model.default => openai/gpt-4.1), keeping the
      # from-zero experience consistent between the wizard and the non-interactive
      # fail-fast guidance. OpenAI is the recommended default (maintainer
      # directive); MiniMax stays a first-class selectable option — listed but
      # NOT pushed or auto-selected — and carries the anthropic_compatible +
      # base_url wiring it needs so picking it still yields a first-turn-working
      # config.
      PROVIDERS = [
        {
          key: "openai",
          label: "OpenAI (GPT) — recommended default",
          provider: "openai",
          model: "gpt-4.1",
          env_var: "OPENAI_API_KEY",
          config: {}
        },
        {
          key: "minimax",
          label: "MiniMax (Anthropic-compatible)",
          provider: "minimax",
          model: "MiniMax-M3",
          env_var: "MINIMAX_API_KEY",
          config: {
            "anthropic_compatible" => true,
            "base_url" => "https://api.minimax.io/anthropic",
            "api_key" => "${MINIMAX_API_KEY}"
          }
        },
        {
          key: "anthropic",
          label: "Anthropic (Claude)",
          provider: "anthropic",
          model: "claude-sonnet-4-5",
          env_var: "ANTHROPIC_API_KEY",
          config: {}
        },
        {
          key: "gemini",
          label: "Google (Gemini)",
          provider: "google",
          model: "gemini-2.5-pro",
          env_var: "GEMINI_API_KEY",
          config: {}
        },
        {
          key: "gateway",
          label: "OpenAI-compatible gateway",
          provider: "gateway",
          model: "auto",
          env_var: "OPENAI_API_KEY",
          config: {
            "openai_compatible" => true,
            "assume_model_exists" => true,
            "base_url" => nil # filled in interactively
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
      #
      # A Ctrl-C MID-wizard — after picking a provider, before pasting the key —
      # used to escape as a raw `Interrupt` backtrace out of `gets`/`noecho`
      # (H2). Catch it here and abort CLEANLY: print "Setup cancelled." and exit
      # 130 (the conventional SIGINT code). Nothing is half-written — #persist!
      # (the only writer of the provider's model.* / .env key) runs ONLY after a
      # non-empty key is obtained, several lines below the interrupt point, so an
      # abort leaves the config at the seeded defaults and re-running `setup`
      # works. The base config.yml/.env `setup` materialized before onboarding
      # are the intended seed files, not partial wizard state.
      def run
        @ui.blank_line
        @ui.info("Welcome to rubino — let's get you connected to a model.")
        @ui.status("No API key is configured yet. Pick a provider (or press Enter to skip).")
        @ui.blank_line

        choice = ask_provider
        return false unless choice

        # When the provider was just CONFIRMED via its already-present env key
        # (F3), that key is the one to use — don't re-ask "use the detected key?"
        # one line later. Otherwise prompt/paste as usual.
        api_key = ask_api_key(choice, skip_env_prompt: @confirmed_env_key)
        return false if api_key.nil? || api_key.empty?

        base_url = ask_base_url(choice)

        persist!(choice, api_key, base_url)
        Rubino.reload_configuration!

        @ui.blank_line
        # Honest copy (#541): the wizard SAVES the key — it does not validate it
        # (no live auth probe; offline/rate-limit safe, matches the norm). A
        # confident "Configured … ✓" read as "validated", so a bogus pasted key
        # got a false green and only broke on the first real turn. Say "Saved"
        # and point at the verify step so the green means "written", not "works".
        @ui.success("Saved #{choice[:label]} with model #{choice[:model]} — run a prompt to verify the key.")
        @ui.status("Saved to #{config_loader.config_path} and #{config_loader.env_path}.")
        @ui.blank_line
        true
      rescue Interrupt
        @output.puts
        @ui.warning("Setup cancelled.")
        exit(130)
      end

      private

      def ask_provider
        # F3: when EXACTLY ONE provider's key is already in the environment,
        # CONFIRM that pick before dropping to the full menu — the choice stays
        # VISIBLE (explicit-control theme) instead of being silently auto-selected,
        # but a bare Enter accepts it so the smooth path stays one keystroke.
        # Ambiguous (>1 key) or none falls straight through to the menu.
        if (detected = single_env_provider)
          @output.print "Detected #{detected[:env_var]} — use #{detected[:provider]}/#{detected[:model]}? " \
                        "[Y/n, or n to pick another]: "
          @output.flush
          ans = read_line.to_s.strip.downcase
          unless %w[n no].include?(ans)
            # Confirmed: the detected env key is the one to use — the api-key step
            # need not re-prompt to reuse it.
            @confirmed_env_key = true
            return detected
          end
          # An explicit "n" means "show me the others" — fall through to the menu.
        end

        PROVIDERS.each_with_index do |p, i|
          @output.puts "  #{i + 1}) #{p[:label]}"
        end

        # Re-prompt on an invalid choice instead of abandoning the wizard on
        # the first typo (#31). Only an explicit skip (empty / `s` / `skip`) or
        # EOF leaves the loop with nil; an out-of-range number just asks again.
        loop do
          @output.print "Choose a provider [1-#{PROVIDERS.size}, Enter to skip]: "
          @output.flush
          raw = read_line
          return nil if raw.nil? || raw.strip.empty? || %w[s skip].include?(raw.strip.downcase)

          idx = raw.strip.to_i
          return PROVIDERS[idx - 1] if idx.between?(1, PROVIDERS.size)

          @ui.warning("Not a valid choice — please pick 1-#{PROVIDERS.size}, or press Enter to skip.")
        end
      end

      # The one provider catalog entry whose env key is present in ENV, or nil
      # when none — or MORE THAN ONE distinct key — is set (ambiguous, so the
      # confirm would be guessing; show the full menu instead). Dedup by env_var
      # so the gateway entry (which reuses OPENAI_API_KEY) doesn't make a lone
      # OpenAI key look ambiguous.
      def single_env_provider
        present = PROVIDERS.select do |p|
          val = ENV.fetch(p[:env_var], nil)
          !val.nil? && !val.empty?
        end
        present.uniq! { |p| p[:env_var] }
        present.one? ? present.first : nil
      end

      # Prompt for the provider's API key — but if it is ALREADY in the
      # environment (e.g. OPENAI_API_KEY, or MINIMAX_API_KEY when the user picks
      # MiniMax), DETECT it and offer to reuse it rather than forcing a paste
      # (the smooth path; matches Hermes/Claude Code/Codex, which all prefer an
      # already-present env key over re-prompting). A bare Enter at the "use it?"
      # prompt accepts the detected key; typing "n" falls through to a manual
      # paste. The returned value is what lands in .env, so reusing the env key
      # also persists it durably for future runs.
      def ask_api_key(choice, skip_env_prompt: false)
        env_key = ENV.fetch(choice[:env_var], nil).to_s.strip
        unless env_key.empty?
          # Already confirmed at the provider step (F3) — reuse without re-asking.
          return env_key if skip_env_prompt

          @output.print "Detected #{choice[:env_var]} in your environment — use it? [Y/n]: "
          @output.flush
          ans = read_line.to_s.strip.downcase
          return env_key unless %w[n no].include?(ans)
        end

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
          value = k == "base_url" && (v.nil? || v.empty?) ? base_url : v
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
