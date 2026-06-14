# frozen_string_literal: true

module Rubino
  module Commands
    # Executes a slash command, rendering its template and feeding it to the agent.
    #
    # `runner:` (optional) is the live Agent::Runner for the interactive REPL.
    # When present, `/status` and `/sessions` can read the current session / model
    # straight off it. It is nil for non-interactive callers (and unit tests that
    # don't exercise those commands), in which case those commands degrade
    # gracefully instead of raising.
    class Executor
      # How many model ids the bare `/model` listing renders before deferring
      # the rest to the completion dropdown.
      MODEL_LIST_LIMIT = 12

      def initialize(loader: nil, ui: nil, runner: nil)
        @loader = loader || Loader.new
        @ui = ui || Rubino.ui
        @runner = runner
      end

      # Attempts to execute input as a slash command.
      # Returns the rendered prompt if it's a command, nil otherwise.
      def try_execute(input)
        return nil unless @loader.slash_command?(input)

        name, arguments = @loader.parse(input)
        return nil unless name

        # Check built-in commands first
        built_in_result = handle_built_in(name, arguments)
        return built_in_result if built_in_result

        # Agent switching (#320): a bare `/<primary>` pins it, a `/<agent>
        # <message>` routes one turn to it. Resolved against the live registry so
        # built-in (build/plan/explore/general) AND user-registered agents are
        # reachable — checked BEFORE custom .md commands so an agent name wins.
        agent_result = agent_switch_handler.handle_command(name, arguments)
        return agent_result if agent_result

        # Look up custom command
        command = @loader.find(name)
        unless command
          @ui.error("unknown command: /#{name}")
          @ui.info("Available: #{help_handler.available_commands.join(", ")}")
          return :handled # Signal that it was handled (even if failed)
        end

        run_custom_command(command, name, arguments)
      end

      # Renders the welcome variant on first interactive boot. Best-effort: a
      # welcome banner must never block the REPL from starting, so any assembler
      # hiccup degrades to no banner rather than a crash. The boot header
      # (workspace/branch/model) is printed by the chat command; this adds only
      # the orientation, with no duplicate identity/session-id renderings.
      def self.welcome(runner: nil, ui: nil)
        new(ui: ui, runner: runner).send(:show_welcome)
      rescue StandardError
        nil
      end

      private

      # Renders a custom command. `--preview` (anywhere in the arguments) shows
      # the resolved prompt and asks for confirmation before sending it to the
      # agent, so the user can see exactly what a command expands to first.
      def run_custom_command(command, name, arguments)
        args, preview = strip_preview_flag(arguments)
        rendered = command.render(args)

        if preview
          show_command_preview(name, rendered)
          return :handled unless confirm_run?(name)
        end

        @ui.status("Running command: /#{name}")
        { prompt: rendered, agent: command.agent, model: command.model }
      end

      # Splits a `--preview` flag out of the argument string, returning
      # [remaining_args, preview?]. Matches `--preview` as a standalone token so
      # it isn't mistaken for part of a longer argument.
      def strip_preview_flag(arguments)
        tokens = arguments.to_s.split(/\s+/)
        preview = tokens.delete("--preview") ? true : false
        [tokens.join(" "), preview]
      end

      def show_command_preview(name, rendered)
        @ui.info("Preview of /#{name} — the prompt that would be sent:")
        @ui.separator
        @ui.info(rendered)
        @ui.separator
      end

      # Asks for confirmation before running a previewed command. The UI #ask
      # returns nil for non-interactive adapters (Null/API), in which case we
      # treat it as "no" so a preview never auto-fires without a human.
      def confirm_run?(name)
        answer = @ui.ask("Run /#{name}? [y/N] ")
        answer.to_s.strip.downcase.start_with?("y")
      end

      def handle_built_in(name, arguments)
        case name
        when "help"
          help_handler.show_help
          :handled
        when "exit", "quit"
          :exit
        when "commands"
          help_handler.show_commands
          :handled
        when "skills"
          skills_handler.handle_skills(arguments)
          :handled
        when "mcp"
          mcp_handler.handle_mcp(arguments)
          :handled
        when "add-dir"
          handle_add_dir(arguments)
          :handled
        when "dirs"
          show_dirs
          :handled
        when "mode"
          handle_mode(arguments)
          :handled
        when "model"
          handle_model(arguments)
          :handled
        when "compact"
          handle_compact
        when "export"
          handle_export(arguments)
          :handled
        when "reasoning"
          handle_reasoning(arguments)
          :handled
        when "think"
          handle_think(arguments)
          :handled
        when "status"
          status_handler.show_status
          :handled
        when "memory"
          memory_handler.handle_memory(arguments)
          :handled
        when "jobs"
          jobs_handler.handle_jobs(arguments)
          :handled
        when "config"
          config_handler.handle_config(arguments)
          :handled
        when "agent"
          # `/agent` lists the switchable primary agents (and the one-shot
          # subagents); `/agent <name>` pins a primary. The sticky switch is a
          # signal the REPL applies to the live runner + Rubino::ActiveAgent.
          agent_switch_handler.handle_picker(arguments)
        when "agents", "tasks"
          agents_handler.handle_agents(arguments)
          # handle_agents delegates to the puts-based UI (info/table), whose
          # methods return nil; without an explicit :handled the falsy result
          # makes try_execute fall through to the unknown-command path (#34).
          :handled
        when "reply"
          agents_handler.handle_reply(arguments)
          :handled
        when "sessions"
          sessions_handler.handle_sessions(arguments)
        when "probe"
          # `/probe <text>` is the discoverable alias for the `? ` prefix. We
          # don't run the side-inference here (the Executor has no LLM seam) —
          # we hand the REPL a {probe:} signal it runs against the live runner's
          # session, then renders+discards. Bare `/probe` just teaches the tip.
          sessions_handler.handle_probe(arguments)
        when "queued"
          # `/queued <msg>` is normally intercepted by the BottomComposer
          # before it ever reaches the Executor (it queues the message for the
          # next turn, like Alt+Enter). Reaching here means there was nothing
          # to queue (bare `/queued`) or no composer owns the input (API/piped
          # mode) — teach the usage instead of "Unknown command".
          @ui.info("Queue a message to run after the current turn: /queued <message>")
          @ui.info("(Alt+Enter queues the current input line the same way; " \
                   "plain Enter interrupts the turn and runs the line next.)")
          :handled
        when "branch"
          # `/branch [name]` forks the CURRENT session at this point into a new
          # saved one and switches into it. The REPL owns the runner/session, so
          # we return a {branch_from:, title:} signal on the SAME channel /new
          # and /sessions use, and it does the build/seed/swap.
          sessions_handler.handle_branch(arguments)
        when "new", "clear"
          # Hand the REPL a signal to rebuild the runner on a brand-new session.
          # The current session is left intact (and will be marked ended on the
          # eventual teardown), so /new is the in-chat counterpart to `--new`.
          # /clear is the muscle-memory alias every other agent CLI ships.
          @ui.success("Starting a fresh session.")
          { new_session: true }
        end
      end

      # The domain handlers the dispatcher delegates to (#193 collaborator
      # pattern). Each is a plain object given the deps it needs (ui/runner);
      # the Executor stays the thin dispatcher/facade over the slash-command
      # case. Memoized so each carries its own per-session state (e.g. the
      # memory backend memo, the watch pastel).
      def agents_handler
        @agents_handler ||= Handlers::Agents.new(ui: @ui)
      end

      def agent_switch_handler
        @agent_switch_handler ||= Handlers::AgentSwitch.new(ui: @ui)
      end

      def sessions_handler
        @sessions_handler ||= Handlers::Sessions.new(ui: @ui, runner: @runner)
      end

      def status_handler
        @status_handler ||= Handlers::Status.new(ui: @ui, runner: @runner)
      end

      def memory_handler
        @memory_handler ||= Handlers::Memory.new(ui: @ui)
      end

      def skills_handler
        @skills_handler ||= Handlers::Skills.new(ui: @ui)
      end

      def mcp_handler
        @mcp_handler ||= Handlers::MCP.new(ui: @ui)
      end

      def jobs_handler
        @jobs_handler ||= Handlers::Jobs.new(ui: @ui)
      end

      def config_handler
        @config_handler ||= Handlers::Config.new(ui: @ui)
      end

      def help_handler
        @help_handler ||= Handlers::Help.new(ui: @ui, loader: @loader)
      end

      # `/mode`          → show current + list
      # `/mode list`     → same
      # `/mode <name>`   → switch (default | plan | yolo)
      #
      # We delegate the actual transition to Rubino::Modes.set so the API
      # adapter and any other caller go through the same gate (and trigger
      # the same `mode_changed` UI event).
      def handle_mode(arguments)
        name = arguments.to_s.strip.downcase.split(/\s+/).first

        if name.nil? || name.empty? || name == "list"
          show_modes
          return
        end

        previous = Rubino::Modes.current
        Rubino::Modes.set(name)
        @ui.mode_changed(Rubino::Modes.current, previous: previous)
        warn_yolo_live_children(previous)
      rescue ArgumentError => e
        @ui.error(e.message)
        @ui.info("Available: #{Rubino::Modes::ALL.join(", ")}")
      end

      # One warning line when an explicit `/mode yolo` lands while background
      # children are live (#152): the gates of already-running subagents drop
      # the moment the mode flips, which is easy to forget mid-session. The
      # explicit command stays unconfirmed — this is information, not friction.
      def warn_yolo_live_children(previous)
        return unless Rubino::Modes.current == Rubino::Modes::YOLO && previous != Rubino::Modes::YOLO

        live = Tools::BackgroundTasks.instance.running.size
        return unless live.positive?

        @ui.warning("⚡ yolo: #{live} running background subagent(s) will now run gated actions unprompted")
      end

      def show_modes
        current = Rubino::Modes.current
        @ui.info("Current mode: #{current} — #{Rubino::Modes.description(current)}")
        @ui.info("Available:")
        Rubino::Modes::ALL.each do |m|
          marker = m == current ? "▸" : " "
          @ui.info("  #{marker} /mode #{m} — #{Rubino::Modes.description(m)}")
        end
      end

      # `/reasoning`         → show current render mode
      # `/reasoning <mode>`  → switch (hidden | collapsed | full)
      #
      # Writes the new mode to display.reasoning on the live configuration so the
      # LLM adapter gate (which reads config) and the CLI render path share one
      # source of truth — no separate per-UI override to drift. An unknown value
      # is rejected with the valid list.
      def handle_reasoning(arguments)
        name = arguments.to_s.strip.downcase.split(/\s+/).first
        previous = Config::ReasoningPrefs.mode(Rubino.configuration)

        if name.nil? || name.empty?
          @ui.reasoning_status(previous) if @ui.respond_to?(:reasoning_status)
          return
        end

        sym = name.to_sym
        unless Config::ReasoningPrefs::RENDER_MODES.include?(sym)
          @ui.error("unknown reasoning mode: #{name}")
          @ui.info("Available: #{Config::ReasoningPrefs::RENDER_MODES.join(", ")}")
          return
        end

        Rubino.configuration.set("display", "reasoning", sym.to_s)
        persist_config("display.reasoning", sym.to_s)
        @ui.reasoning_changed(sym, previous: previous) if @ui.respond_to?(:reasoning_changed)
      end

      # `/think`         → show current effort
      # `/think <level>` → switch (off | low | medium | high)
      #
      # Writes thinking.effort on the live configuration; the adapter derives the
      # thinking-token budget from it on the next turn. An unknown value is
      # rejected with the valid list.
      def handle_think(arguments)
        name = arguments.to_s.strip.downcase.split(/\s+/).first
        previous = Config::ReasoningPrefs.effort(Rubino.configuration) ||
                   Config::ReasoningPrefs::DEFAULT_EFFORT

        if name.nil? || name.empty?
          @ui.think_status(previous) if @ui.respond_to?(:think_status)
          return
        end

        sym = name.to_sym
        unless Config::ReasoningPrefs::EFFORTS.include?(sym)
          @ui.error("unknown effort: #{name}")
          @ui.info("Available: #{Config::ReasoningPrefs::EFFORTS.join(", ")}")
          return
        end

        Rubino.configuration.set("thinking", "effort", sym.to_s)
        persist_config("thinking.effort", sym.to_s)
        @ui.think_changed(sym, previous: previous) if @ui.respond_to?(:think_changed)
      end

      # `/model`          → show current model/provider + the known models
      # `/model <name>`   → switch the LIVE session model
      #
      # The switch writes model.default through Config::Writer (the same
      # persist path /think uses) AND retargets the live runner, so the very
      # next turn hits the new model — no restart. The known-models list comes
      # from the ruby_llm registry for the ACTIVE provider; custom backends
      # (minimax/gateway) aren't enumerable there, so they degrade to the
      # current model + a usage hint instead of an invented hardcoded list.
      def handle_model(arguments)
        name = arguments.to_s.strip.split(/\s+/).first

        if name.nil? || name.empty?
          show_model
          return
        end

        previous = status_model
        if name == previous
          @ui.info("Already on #{name}.")
          return
        end

        # Guard against a label that won't actually take effect — the status
        # bar must never advertise a model the next turn won't run on.
        return unless model_switch_ok?(name)

        Rubino.configuration.set("model", "default", name)
        persist_config("model.default", name)
        @runner.switch_model!(name) if @runner.respond_to?(:switch_model!)
        # Forget per-provider thinking rejections recorded this session: the
        # new model may sit on a provider that does support a budget (and the
        # MiniMax-family default is re-derived per turn from the new id).
        LLM::ThinkingSupport.reset!
        @ui.success("model: #{previous} → #{name} (persisted; applies from the next turn)")
        warn_cross_provider_model(name)
      end

      # True when switching to +name+ will genuinely change what the next turn
      # runs on; false (with an honest error) when it would only relabel the
      # status bar without changing routing. Two reject cases:
      #   1. The serving provider HAS a catalog but doesn't list +name+ — a
      #      typo/unknown id. Reject so we don't persist a model the backend
      #      can't serve (and the footer doesn't lie).
      #   2. The provider is explicitly PINNED (e.g. "minimax") with NO catalog
      #      to enumerate — the id can't re-route (the pin owns routing) and
      #      isn't verifiable, so accepting it would just paint a fake name on
      #      the footer while requests keep hitting the pinned backend.
      # With no pin AND no catalog, the id itself drives routing (auto pattern
      # match), so the switch is real — allow it.
      def model_switch_ok?(name)
        explicit = Rubino.configuration.model_provider
        pinned   = !(explicit.nil? || explicit.to_s.empty? || explicit == "auto")
        provider = pinned ? explicit : LLM::ProviderResolver.resolve(name)
        ids      = LLM::ModelCatalog.ids_for(provider)

        if ids.any?
          return true if ids.include?(name)

          @ui.error("'#{name}' is not a known model for provider '#{provider}' — " \
                    "not switched. Run `/model` to see the valid ids.")
          return false
        end

        if pinned
          @ui.error("'#{name}' can't be verified for provider '#{provider}', and the " \
                    "provider is pinned — requests would still route to '#{provider}'. " \
                    "Not switched (the status bar would otherwise show a model that isn't in use). " \
                    "Change the backend with model.provider in config.")
          return false
        end

        true
      end

      def show_model
        current  = status_model
        provider = active_provider(current)
        @ui.info("Current model: #{current} (provider: #{provider})")

        ids = LLM::ModelCatalog.ids_for(provider)
        if ids.empty?
          explicit = Rubino.configuration.model_provider
          if explicit.nil? || explicit.to_s.empty? || explicit == "auto"
            @ui.info("No model catalog for provider '#{provider}' — `/model <name>` still " \
                     "switches (the id picks the provider).")
          else
            @ui.info("Provider '#{provider}' is pinned and has no model catalog — the model id " \
                     "is just a label here and `/model <name>` won't change the backend. " \
                     "Switch backends via model.provider in config.")
          end
          return
        end

        @ui.info("Known models for #{provider}:")
        ids.first(MODEL_LIST_LIMIT).each do |id|
          marker = id == current ? "▸" : " "
          @ui.info("  #{marker} /model #{id}")
        end
        rest = ids.size - MODEL_LIST_LIMIT
        @ui.info("  … and #{rest} more (type `/model ` for the full dropdown)") if rest.positive?
      end

      # The model the next turn will run on — the live session's model, the
      # runner's model_id, or the configured default (in that order). Shared by
      # /model (here) and the /status panel (Handlers::Status reads it too).
      def status_model
        @runner&.session&.dig(:model) ||
          (@runner.respond_to?(:model_id) ? @runner.model_id : nil) ||
          Rubino.configuration.model_default
      end

      # The provider the next turn will actually route through — the single
      # ProviderResolver seam AdapterFactory uses, fed with the configured
      # explicit provider (or "auto" pattern-matching the model id).
      def active_provider(model_id)
        LLM::ProviderResolver.resolve(model_id, explicit_provider: Rubino.configuration.model_provider)
      rescue StandardError
        "(unknown)"
      end

      # An explicit model.provider pins routing regardless of model id, so
      # `/model claude-x` under provider "minimax" keeps hitting MiniMax's
      # endpoint. One informational line when the new id pattern-matches a
      # different provider than the pinned one — gateway excepted, since a
      # gateway proxies arbitrary model ids by design.
      def warn_cross_provider_model(model_id)
        explicit = Rubino.configuration.model_provider
        return if explicit.nil? || explicit == "auto" || explicit == "gateway"

        implied = LLM::ProviderResolver.resolve(model_id)
        return if implied == explicit

        @ui.info("Requests still route via provider '#{explicit}' — set model.provider to switch backends.")
      rescue StandardError
        nil
      end

      # `/compact` — manual compaction NOW, the same Context::Compressor +
      # compression_started/finished pipeline the automatic threshold path
      # runs, plus a tokens before→after report. Compaction lands in a CHILD
      # session (head + summary + tail), so on success we hand the REPL a
      # {compact_into:} signal and it swaps the runner into the child — the
      # next turn runs on the compacted context.
      def handle_compact
        session = @runner&.session
        unless session && Session::Repository.new.persisted?(session[:id])
          @ui.error("nothing to compact — this session has no saved messages yet")
          return :handled
        end

        store  = Session::Store.new
        before = estimate_session_tokens(store, session[:id], model_id: session[:model])

        @ui.compression_started
        result = Context::Compressor.new(session_id: session[:id]).compact!

        if result[:skipped]
          @ui.info("Nothing to compact yet — the session is still below the protected head/tail size.")
          return :handled
        end

        @ui.compression_finished(result)
        after = estimate_session_tokens(store, result[:target_session_id], model_id: session[:model])
        @ui.info("Context: ~#{before} → ~#{after} tokens (#{result[:original_messages]} → " \
                 "#{result[:compacted_messages]} messages).")
        { compact_into: result[:target_session_id] }
      rescue StandardError => e
        @ui.error("compaction failed: #{e.message}")
        :handled
      end

      # The same chars/4 estimate the compaction thresholds and the status bar
      # run on, over a session's stored messages.
      def estimate_session_tokens(store, session_id, model_id:)
        budget = Context::TokenBudget.new(model_id: model_id, config: Rubino.configuration)
        budget.estimate_tokens(store.for_session(session_id).map { |m| { content: m.content } })
      end

      # `/export [path]` — write the session transcript as clean markdown via
      # Session::Exporter (user/assistant turns, tool calls as one-liners,
      # reasoning omitted). Default path ./rubino-session-<id8>.md.
      def handle_export(arguments)
        session = @runner&.session
        unless session
          @ui.error("no live session to export")
          return
        end

        path = arguments.to_s.strip
        target = Session::Exporter.new(session).write(path.empty? ? nil : path)
        @ui.success("exported → #{target}")
      rescue StandardError => e
        @ui.error("export failed: #{e.message}")
      end

      # Write-through of a /reasoning // /think switch to config.yml so it
      # survives the session, as docs/commands.md promises (#131). The in-memory
      # set above stays authoritative for THIS session either way; a disk
      # failure degrades to the old session-only behavior with a warning, never
      # a broken command.
      def persist_config(key_path, value)
        path = Config::Loader.new.config_path
        Config::Writer.new(config_path: path).set(key_path, value)
      rescue StandardError => e
        @ui.warning("could not persist #{key_path} to config: #{e.message}")
      end

      # --- welcome -----------------------------------------------------------
      #
      # First-run guidance — the counterpart to /status (Handlers::Status).
      # `.welcome` (public, above) orients a newcomer: one identity line + what
      # to DO next. NOT the state dump (#82); the at-a-glance panel lives in
      # /status. This is the private instance method it calls.

      # Color diet (P8): ONE cyan identity line; the hint commands are the
      # only other accent (they're actionable pointers); descriptions plain.
      def show_welcome
        @ui.separator
        @ui.info("rubino — ask in plain language; it reads, edits, and runs things for you.")
        @ui.blank_line
        @ui.status("  Ask anything, or try:")
        @ui.hint_row("/status", "what's going on right now")
        @ui.hint_row("/sessions", "resume past work")
        @ui.hint_row("/memory", "what I recall about you")
        @ui.hint_row("/help", "all commands and keys")
        @ui.separator
      end
      # --- /add-dir & /dirs --------------------------------------------------
      #
      # Mid-session workspace management, mirroring Claude Code's --add-dir.
      # `/add-dir <path>` adds an extra allowed root (write/edit can then reach
      # files under it) and runs the folder-trust gate so its AGENTS.md/skills
      # are only honored once vouched for. `/dirs` lists the current roots.

      def handle_add_dir(arguments)
        path = arguments.to_s.strip
        if path.empty?
          @ui.info("Usage: /add-dir <path> — adds an extra allowed workspace directory.")
          return
        end

        real = Rubino::Workspace.add(path)
        @ui.success("Added workspace root: #{real}")
        # Gate the freshly-added dir interactively (same one-time prompt as boot).
        CLI::TrustGate.new(ui: @ui, interactive: true).ensure_trust(real)
      rescue ArgumentError => e
        @ui.error("/add-dir #{path}: #{e.message}")
      end

      def show_dirs
        roots = Rubino::Workspace.canonical_roots
        @ui.info("Workspace roots (#{roots.size}):")
        roots.each_with_index do |dir, i|
          marker = i.zero? ? "▸" : " "
          # "withheld" only applies to a dir that HAS project context/skills the
          # user declined to load. A plain scratch dir (no AGENTS.md, no skills)
          # has nothing to withhold — labelling it "untrusted" alarms for no
          # reason (MF-6). Show its real state instead.
          trust =
            if Rubino::Trust.trusted?(dir) || !Rubino::CLI::TrustGate.gateworthy?(dir)
              ""
            else
              "  (not trusted — its AGENTS.md/skills aren't loaded; run /add-dir to trust)"
            end
          @ui.info("  #{marker} #{dir}#{trust}")
        end
        @ui.info("Add more with /add-dir <path>")
      end
    end
  end
end
