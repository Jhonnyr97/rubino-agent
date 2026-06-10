# frozen_string_literal: true

require "pastel"
require "time"

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
      # How many times the parked-child approval prompt re-renders after an
      # empty/aborted read (#144) before giving up and leaving the child parked.
      APPROVAL_ASK_ATTEMPTS = 3

      # Render order for the /jobs counts header (#187) — lifecycle order, not
      # the arbitrary GROUP BY order (any unknown status is appended).
      JOB_STATUS_ORDER = %w[queued running completed failed dead].freeze

      # The /skills toggle verbs (#188) — the same registry-validated
      # StateRepository write the HTTP API and `rubino skills` CLI run.
      SKILL_TOGGLE_VERBS = %w[enable disable].freeze

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

        # Look up custom command
        command = @loader.find(name)
        unless command
          @ui.error("unknown command: /#{name}")
          @ui.info("Available: #{available_commands.join(", ")}")
          return :handled # Signal that it was handled (even if failed)
        end

        run_custom_command(command, name, arguments)
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
          show_help
          :handled
        when "exit", "quit"
          :exit
        when "commands"
          show_commands
          :handled
        when "skills"
          handle_skills(arguments)
          :handled
        when "mcp"
          handle_mcp(arguments)
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
        when "reasoning"
          handle_reasoning(arguments)
          :handled
        when "think"
          handle_think(arguments)
          :handled
        when "status"
          show_status
          :handled
        when "memory"
          handle_memory(arguments)
          :handled
        when "jobs"
          handle_jobs(arguments)
          :handled
        when "config"
          handle_config(arguments)
          :handled
        when "agents", "tasks"
          handle_agents(arguments)
          # handle_agents delegates to the puts-based UI (info/table), whose
          # methods return nil; without an explicit :handled the falsy result
          # makes try_execute fall through to the unknown-command path (#34).
          :handled
        when "reply"
          handle_reply(arguments)
          :handled
        when "sessions"
          handle_sessions(arguments)
        when "probe"
          # `/probe <text>` is the discoverable alias for the `? ` prefix. We
          # don't run the side-inference here (the Executor has no LLM seam) —
          # we hand the REPL a {probe:} signal it runs against the live runner's
          # session, then renders+discards. Bare `/probe` just teaches the tip.
          handle_probe(arguments)
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
          handle_branch(arguments)
        when "new"
          # Hand the REPL a signal to rebuild the runner on a brand-new session.
          # The current session is left intact (and will be marked ended on the
          # eventual teardown), so /new is the in-chat counterpart to `--new`.
          @ui.success("Starting a fresh session.")
          { new_session: true }
        end
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

      # --- /status & welcome -------------------------------------------------
      #
      # Two DISTINCT panels over the same assembler services (Modes,
      # Session::Repository, Memory::Store, BackgroundTasks, Skills::Registry):
      #
      #   .welcome   — first-run guidance. Orients a newcomer: one identity line
      #                + what to DO next. NOT the state dump (#82).
      #   #show_status — the at-a-glance state panel: model/mode/session plus the
      #                things a status check actually wants — approval policy,
      #                provider/connection, and the tool roster (#82). No
      #                onboarding hints; the sessions list lives in /sessions.

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

      def show_welcome
        @ui.separator
        @ui.info("rubino — ask in plain language; it reads, edits, and runs things for you.")
        @ui.blank_line
        @ui.info("  Ask anything, or try:  /status   what's going on right now")
        @ui.info("                         /sessions resume past work")
        @ui.info("                         /memory   what I recall about you")
        @ui.info("                         /help     all commands and keys")
        @ui.separator
      end

      def show_status
        @ui.separator
        @ui.info("  model      #{status_model}")
        @ui.info("  provider   #{status_provider_line}")
        @ui.info("  mode       #{Rubino::Modes.current} — #{Rubino::Modes.description}")
        @ui.info("  display    #{status_display_line}   (use /reasoning · /think)")
        @ui.info("  approvals  #{status_approvals_line}")
        @ui.info("  session    #{status_session_line}")
        @ui.info("  tools      #{status_tools_line}")
        # MCP only when servers are configured (#182/#186) — a non-MCP user's
        # /status stays exactly as before, and MCP tools stop being invisibly
        # mixed into the truncated tools line as the only trace of MCP.
        @ui.info("  mcp        #{status_mcp_line}   (use /mcp)") if Rubino::MCP.enabled?
        if (dirs = status_dirs_line)
          @ui.info("  dirs       #{dirs}   (use /dirs)")
        end
        @ui.info("  memory     #{status_memory_line}   (use /memory)")
        @ui.info("  skills     #{status_skills_line}   (use /skills)")
        @ui.info("  background #{status_background_line}   (use /agents)")
        if (jobs = status_jobs_line)
          @ui.info("  jobs       #{jobs}   (use /jobs)")
        end
        @ui.separator
      end

      # The persisted display prefs (#186): /reasoning and /think write config
      # but were invisible — not in the chip, not in /status.
      def status_display_line
        mode   = Config::ReasoningPrefs.mode(Rubino.configuration)
        effort = Config::ReasoningPrefs.effort(Rubino.configuration) ||
                 Config::ReasoningPrefs::DEFAULT_EFFORT
        "reasoning: #{mode} · effort: #{effort}"
      rescue StandardError
        "(unavailable)"
      end

      # Workspace roots + trust (#186) — trust is the #1 "why are my
      # skills/AGENTS.md not loading" confusion. Only earns a line when there
      # is something to say (>1 root or any untrusted); nil otherwise.
      def status_dirs_line
        roots     = Rubino::Workspace.canonical_roots
        untrusted = roots.count { |d| !Rubino::Trust.trusted?(d) }
        return nil if roots.size <= 1 && untrusted.zero?

        line = "#{roots.size} root#{"s" if roots.size != 1}"
        untrusted.positive? ? "#{line} · #{untrusted} untrusted (context/skills withheld)" : line
      rescue StandardError
        nil
      end

      # The persistent jobs queue (#186) — distinct from the in-process
      # `background` subagents line. Only earns a line when nonzero; nil (no
      # line) when the queue is empty or unreadable.
      def status_jobs_line
        queue   = Jobs::Queue.new
        pending = queue.pending_count
        failed  = queue.failed_count
        return nil unless pending.positive? || failed.positive?

        [("#{pending} pending" if pending.positive?),
         ("#{failed} failed" if failed.positive?)].compact.join(" · ")
      rescue StandardError
        nil
      end

      def status_model
        @runner&.session&.dig(:model) ||
          (@runner.respond_to?(:model_id) ? @runner.model_id : nil) ||
          Rubino.configuration.model_default
      end

      # The configured provider — the "what am I talking to" line a status
      # check wants. We report the configured target, not a live probe (a
      # health round-trip would make /status slow and flaky).
      def status_provider_line
        Rubino.configuration.model_provider || "(default)"
      rescue StandardError
        "(unavailable)"
      end

      # One-line approval-policy summary so a newcomer knows what will prompt.
      # Mode is authoritative: yolo skips every approval, plan filters mutating
      # tools out entirely; otherwise approvals come from config.
      def status_approvals_line
        case Rubino::Modes.current
        when :yolo then "skipped (yolo mode — nothing prompts)"
        when :plan then "read-only mode — no edits/shell to approve"
        else            "from config (mutating commands prompt)"
        end
      end

      # A compact roster of the tools the agent can actually use right now
      # (mode filters the registry), so /status answers "what can it DO".
      def status_tools_line
        names = Tools::Registry.instance.enabled_tools.map(&:name).sort
        return "(none)" if names.empty?

        truncate(names.join(", "), 64)
      rescue StandardError
        "(unavailable)"
      end

      # `2 servers · 1 reachable · 14 tools` — reads the LIVE booted manager
      # (no client → 0 reachable), never re-spawns servers.
      def status_mcp_line
        servers   = mcp_servers_config.size
        reachable = mcp_health.count { |h| h[:alive] }
        tools     = Tools::Registry.all.count { |t| t.is_a?(Rubino::MCP::MCPToolWrapper) }
        "#{servers} server#{"s" if servers != 1} · #{reachable} reachable · #{tools} tool#{"s" if tools != 1}"
      rescue StandardError
        "(unavailable)"
      end

      def status_session_line
        session = @runner&.session
        return "(none)" unless session

        id    = session[:id].to_s[0..7]
        title = session[:title].to_s.strip
        title = title.empty? ? "(untitled)" : %("#{title}")
        msgs  = status_message_count(session)
        "#{id}  #{title}#{" · #{msgs} msgs" if msgs}"
      end

      # The session's message count, read LIVE from the message store. The
      # in-memory session hash's :message_count is a boot-time snapshot the
      # streaming path never refreshes, so /status reported a permanent
      # "0 msgs" while the DB had every turn (#159). Counting the persisted
      # rows also matches the "Loaded N prior messages" resume banner.
      def status_message_count(session)
        Session::Store.new.count(session[:id])
      rescue StandardError
        session[:message_count]
      end

      # /status must count facts on the ACTIVE backend — the same store /memory
      # and the `rubino memory` CLI read via Memory::Backends.build — not the
      # legacy `:memories` table Memory::Store is hardwired to (#83).
      def status_memory_line
        backend = Rubino.configuration.dig("memory", "backend") || Memory::Backends::DEFAULT_NAME
        "backend: #{backend} · #{memory_backend.count} facts"
      rescue StandardError
        "(unavailable)"
      end

      def status_skills_line
        registry = Skills::Registry.trusted
        all      = registry.all
        enabled  = all.count { |s| registry.enabled?(s.name) }
        line     = "#{all.size} available, #{enabled} enabled"
        # WHICH skill is pinned (#186) — the chip shows it but the canonical
        # state dump omitted it.
        active = Rubino::ActiveSkill.current
        active ? "#{line} · active: #{active}" : line
      rescue StandardError
        "(unavailable)"
      end

      def status_background_line
        entries = Tools::BackgroundTasks.instance.list
        running = entries.count { |e| e.status == :running }
        ids     = entries.first(3).map(&:id).join(", ")
        line    = "#{running} running · #{entries.size} total"
        ids.empty? ? line : "#{line} (#{ids})"
      rescue StandardError
        "(unavailable)"
      end

      # --- /memory -----------------------------------------------------------
      #
      # In-chat read/manage view over the *active* memory backend — the same
      # store the agent loop, the `rubino memory` CLI (#94) and the HTTP
      # `/v1/memory` ops resolve via `Memory::Backends.build`. The agent's
      # MemoryTool does autonomous writes; this is the human's window into it.
      #
      #   /memory                  → backend + count + recent facts
      #   /memory --all            → recent facts INCLUDING retired, marked (#184)
      #   /memory <query>          → substring search over content
      #   /memory search <query>   → same search, explicit subcommand
      #   /memory show <id>        → one fact in full, with the temporal chain (#184)
      #   /memory forget <id>      → delete a fact
      #   /memory backend          → active + available backends (#184)

      def handle_memory(arguments)
        args = arguments.to_s.strip

        if args.empty?
          show_memory_summary
        elsif args == "--all"
          show_memory_summary(include_retired: true)
        elsif args.match?(/\Ashow\b/)
          id = args[/\Ashow\s+(\S+)\z/, 1]
          id ? show_memory(id) : @ui.info("Usage: /memory show <id>")
        elsif args.match?(/\Abackend\b/)
          show_memory_backend(args[/\Abackend\s+(\S+)\z/, 1])
        elsif args.match?(/\Aforget\b/)
          id = args[/\Aforget\s+(\S+)\z/, 1]
          id ? forget_memory(id) : @ui.info("Usage: /memory forget <id>")
        elsif args.match?(/\Asearch\b/)
          # `search` is a subcommand token, not a query term (#59): bare
          # `/memory search` falls back to the summary instead of searching
          # for the literal word "search".
          query = args[/\Asearch\s+(.+)\z/, 1]
          query ? search_memory(query) : show_memory_summary
        else
          search_memory(args)
        end
      end

      # `/memory show <id>` (#184): a REAL id lookup (the store resolves the
      # short-id prefix), not a substring search over content — an id used to
      # match nothing. Rendering (incl. the temporal chain: Retired /
      # Superseded by) is shared with the `rubino memory show` CLI verb.
      def show_memory(id)
        memory = memory_backend.find(id)
        if memory.nil?
          @ui.error("no fact with id #{id}.")
          return
        end

        CLI::MemoryCommand.render(memory, ui: @ui)
      end

      # `/memory backend [name]` (#184): shows the active + available
      # backends in-chat. SWITCHING stays CLI-only on purpose: every consumer
      # (the lifecycle's retriever/flusher, the memory tool, this executor)
      # memoizes its built backend, so an in-process flip would leave the live
      # loop writing to the OLD store while /memory reads the new one — a
      # half-applied switch. The CLI verb writes config and a restart applies
      # it everywhere at once.
      def show_memory_backend(name)
        CLI::MemoryCommand.render_active_backend(ui: @ui)
        return unless name

        @ui.info("Switching is CLI-only: run `rubino memory backend #{name}` " \
                 "(a restart applies it to the whole agent).")
      end

      def show_memory_summary(include_retired: false)
        store    = memory_backend
        backend  = Rubino.configuration.dig("memory", "backend") || Memory::Backends::DEFAULT_NAME
        @ui.info("backend  #{backend}   ·   #{store.count} facts")

        memories = store.list(limit: 10, include_retired: include_retired)
        if memories.empty?
          @ui.info("No facts stored yet — the agent records them as it learns about you.")
          return
        end

        render_memory_table(memories)
        @ui.info("/memory <query>   ·   /memory show <id>   ·   /memory forget <id>")
      end

      def search_memory(query)
        needle  = query.downcase
        matches = memory_backend.list(limit: 200)
                                .select { |m| m[:content].to_s.downcase.include?(needle) }
        if matches.empty?
          @ui.info("No facts matching #{query.inspect}.")
          return
        end

        shown = matches.first(20)
        @ui.info(%(#{shown.length} match#{"es" if shown.length != 1} for #{query.inspect}))
        # A targeted search must SHOW the matched fact in full — the list-view's
        # narrow truncation hides exactly the part the user searched for (#85).
        # Print each match's full content, wrapping to the terminal width.
        shown.each { |m| render_memory_match(m) }
        @ui.info("/memory forget <id> to delete one")
      end

      # One searched fact, content shown end-to-end (wrapped, never truncated).
      def render_memory_match(memory)
        head    = "#{memory[:id].to_s[0..7]}  #{memory[:kind]}  "
        content = memory[:content].to_s.gsub(/\s+/, " ").strip
        wrap_skill_line(head, content).each { |line| @ui.info(line) }
      end

      def forget_memory(id)
        store  = memory_backend
        memory = store.find(id)
        if memory.nil?
          @ui.error("no fact with id #{id}.")
          return
        end

        store.delete(memory[:id])
        @ui.success(%(Forgot #{memory[:id][0..7]} "#{truncate(memory[:content], 60)}"))
      end

      # Resolve the *configured* memory backend (default: sqlite tiny-Zep), the
      # same store the agent loop, the `rubino memory` CLI and the HTTP
      # `/v1/memory` ops use. The old `Memory::Store.new` was hardwired to the
      # legacy `:memories` table and ignored `memory.backend`, so in-chat
      # `/memory` never saw the facts the agent actually persists (#106).
      def memory_backend
        @memory_backend ||= Memory::Backends.build
      end

      # The retired tombstone marker is shared with `rubino memory list --all`
      # (CLI::MemoryCommand.retired_marker) so both surfaces speak one dialect.
      def render_memory_table(memories)
        rows = memories.map do |m|
          [m[:id].to_s[0..7], m[:kind].to_s,
           "#{truncate(m[:content], 60)}#{CLI::MemoryCommand.retired_marker(m)}"]
        end
        @ui.table(headers: %w[ID Kind Content], rows: rows)
      end

      # --- /jobs ---------------------------------------------------------------
      #
      # In-chat window into the PERSISTENT jobs queue (#187) — the queue the
      # agent itself feeds mid-session (DistillSkillJob after tool-heavy turns,
      # memory extraction), distinct from the in-process /agents subagents.
      # Read-mostly: `process`/`worker` stay CLI-only (they are daemons, not
      # session actions).
      #
      #   /jobs        → status counts + the recent-jobs table (the SAME
      #                  rendering as `rubino jobs list` — JobsCommand.render_list)
      #   /jobs <id>   → one job in full (attempts, payload, last error);
      #                  short-id prefixes resolve, like /memory show

      def handle_jobs(arguments)
        id = arguments.to_s.strip.split(/\s+/).first
        id.nil? ? show_jobs_list : show_job_detail(id)
      end

      def show_jobs_list
        queue  = Jobs::Queue.new
        counts = queue.counts
        if counts.empty?
          @ui.info("No jobs yet — the agent enqueues background work " \
                   "(skill distillation, memory extraction) as you chat.")
          return
        end

        ordered = (JOB_STATUS_ORDER & counts.keys) + (counts.keys - JOB_STATUS_ORDER)
        @ui.info(ordered.map { |status| "#{counts[status]} #{status}" }.join("  ·  "))
        CLI::JobsCommand.render_list(queue.list, ui: @ui)
        @ui.info("/jobs <id> for detail   ·   `rubino jobs process` runs pending ones now")
      end

      def show_job_detail(id)
        job = Jobs::Queue.new.find(id)
        if job.nil?
          @ui.error("no job with id #{id}.")
          @ui.info("List them with /jobs")
          return
        end

        @ui.info("#{job[:id][0..7]}  #{job[:type]}  ·  #{job[:status]}")
        @ui.info("  attempts  #{job[:attempts]}/#{job[:max_attempts]}")
        @ui.info("  run_at    #{job[:run_at]}")
        @ui.info("  created   #{job[:created_at]}")
        @ui.info("  payload   #{truncate(job[:payload_json], 200)}")
        error = job[:last_error].to_s
        @ui.error(error) unless error.empty?
      end

      # --- /config -------------------------------------------------------------
      #
      # In-chat read/set over the SAME effective config (file merged over
      # defaults) the `rubino config` CLI verbs use (#187) — checking
      # `memory.backend` no longer means quitting the REPL. Rendering is
      # shared with the CLI (CLI::ConfigCommand.render_get / .render_show),
      # so secret-named keys are masked identically on both surfaces.
      #
      #   /config                  → config file path + usage hint
      #   /config show             → the full merged config, secrets masked
      #   /config path             → the config file path
      #   /config <key>            → get (dot-notation; `get <key>` also works)
      #   /config <key> <value>    → set: the same Config::Writer write-through
      #                              /reasoning uses (`set <key> <value>` too)

      def handle_config(arguments)
        tokens = arguments.to_s.strip.split(/\s+/)
        case tokens.first
        when nil    then show_config_summary
        when "show" then CLI::ConfigCommand.render_show(ui: @ui)
        when "path" then @ui.info(Config::Loader.new.config_path)
        when "get"  then config_get(tokens[1])
        when "set"  then config_set(tokens[1], tokens[2..])
        else
          tokens.length == 1 ? config_get(tokens.first) : config_set(tokens.first, tokens[1..])
        end
      end

      def show_config_summary
        @ui.info("config  #{Config::Loader.new.config_path}")
        @ui.info("/config show   ·   /config <key>   ·   /config <key> <value>")
      end

      def config_get(key)
        if key.to_s.empty?
          @ui.info("Usage: /config get <key>  (dot-notation, e.g. memory.backend)")
          return
        end

        CLI::ConfigCommand.render_get(key, ui: @ui)
      end

      # Write-through + live update, the same pair /reasoning and /think run
      # (#131): the file write makes the change survive the session; the
      # in-memory set applies it to config reads from the next turn. The echo
      # is masked like `config show` so a freshly-set api_key never lands in
      # the scrollback. Consumers that memoize their config (e.g. the memory
      # backend) still need a restart — same caveat as the CLI verb.
      def config_set(key, value_tokens)
        value = Array(value_tokens).join(" ")
        if key.to_s.empty? || value.empty?
          @ui.info("Usage: /config set <key> <value>")
          return
        end

        writer = Config::Writer.new(config_path: Config::Loader.new.config_path)
        writer.set(key, value)
        coerced = writer.get(key)
        apply_config_live(key, coerced)
        @ui.success("#{key} = #{CLI::ConfigCommand.redact(coerced, key: key.split(".").last)}   " \
                    "(persisted; applies from the next turn — memoizing consumers need a restart)")
      rescue ConfigurationError => e
        @ui.error(e.message)
      end

      # Mirrors the Writer's (already validated + coerced) value onto the live
      # configuration. Best-effort: the merged in-memory tree can disagree
      # with the file's shape (a default-valued scalar where the file grew a
      # section), in which case the persisted value still applies on restart.
      def apply_config_live(key, value)
        Rubino.configuration.set(*key.split("."), value)
      rescue StandardError
        @ui.warning("#{key} persisted to config.yml but could not be applied live — restart to pick it up")
      end

      # --- /agents (alias /tasks) -------------------------------------------
      #
      # The "see what other agents do" surface. Lists background subagents from
      # the BackgroundTasks registry (the async `task` substrate), drills into a
      # single one's result/error, and can stop a running one.
      #
      #   /agents                 → list
      #   /agents <id>            → drill-in (result / error / status)
      #   /agents <id> --stop     → cancel a running subagent

      def handle_agents(arguments)
        args = arguments.to_s.strip

        if args.empty?
          show_agents_list
          return
        end

        tokens = args.split(/\s+/)
        stop   = tokens.delete("--stop") ? true : false
        id     = tokens.shift

        if id.nil? || id.empty?
          show_agents_list
        elsif stop
          stop_agent(id)
        elsif tokens.first == "steer"
          steer_agent(id, dequote(tokens[1..].join(" ")))
        elsif tokens.first == "probe"
          probe_agent(id, dequote(tokens[1..].join(" ")))
        else
          show_agent_detail(id)
        end
      end

      # parent->child STEER: a fire-and-forget note that enters the child\'s
      # context at its next turn boundary (Loop#inject_steered_input). Pushes onto
      # the child\'s steering queue via BackgroundTasks#steer — the SAME wire the
      # human uses to steer the parent. Echoed with the existing steer vocabulary
      # (▸, "enters child context") + a card repaint so the parked note shows.
      def steer_agent(id, text)
        if text.to_s.strip.empty?
          @ui.error(%(usage: /agents #{id} steer "your note"))
          return
        end

        if Tools::BackgroundTasks.instance.steer(id, text)
          @ui.info("steer ▸ #{id} ← #{truncate(text, 80)}  (parked · enters child context next turn)")
          @ui.set_subagent_cards if @ui.respond_to?(:set_subagent_cards)
        else
          @ui.error("cannot steer #{id} — no such running subagent.")
        end
      end

      # parent->child PROBE: an EPHEMERAL read-only peek. Snapshots the child\'s
      # current messages, runs ONE side-inference ([child messages] + question) on
      # the child\'s own model, prints the answer in a dashed "ephemeral · not
      # saved" aside, and DISCARDS it — nothing is appended to the child\'s
      # history, nothing enters the timeline. The absence of any saved/timeline
      # entry is itself the signal that the peek changed nothing.
      def probe_agent(id, question)
        if question.to_s.strip.empty?
          @ui.error(%(usage: /agents #{id} probe "your question"))
          return
        end

        entry = Tools::BackgroundTasks.instance.find(id)
        unless entry
          @ui.error("cannot probe #{id} — no such subagent.")
          return
        end

        @ui.info(pastel.dim("┄┄ probe → #{id} ┄┄  (ephemeral · not saved · child trajectory unchanged)"))
        # A probe answers from the child's context AT THIS INSTANT; right after
        # spawn that context is still empty and the child honestly says it isn't
        # working on anything yet — hint so that doesn't read as broken (#112).
        if entry.tool_count.to_i.zero?
          @ui.info(pastel.dim("   (snapshot at this instant — the child just started and its " \
                              "context is still empty; probe again in a moment)"))
        end
        @ui.info("?  #{question}")
        # The peek is a synchronous side-inference (seconds of model wait) with
        # nothing streaming — show the same thinking row /probe got in #58 so
        # the gap before the ⟵ answer never looks frozen (#146). TTY only;
        # Null/API adapters and pipes stay silent.
        probe_thinking_started
        answer = begin
          Tools::SubagentProbe.new.peek(entry: entry, question: question)
        ensure
          probe_thinking_finished
        end
        @ui.info("⟵  #{answer}")
        @ui.info(pastel.dim("┄┄ end probe (nothing was saved to #{id}) ┄┄"))
      end

      # The /agents probe wait indicator (#146) — same machinery and guards as
      # CLI::ChatCommand#probe_thinking_started gave /probe (#58).
      def probe_thinking_started
        return unless $stdout.tty? && @ui.respond_to?(:thinking_started)

        @ui.thinking_started
      end

      def probe_thinking_finished
        @ui.thinking_finished if @ui.respond_to?(:thinking_finished)
      end

      # child->parent ASK_PARENT answer: /reply <id> <answer>. Resolves the
      # child\'s ask gate (Run::ApprovalGate#decide) so a BLOCKING ask unwinds with
      # the answer as its tool result, and ALSO pushes the answer onto the child\'s
      # steer queue so a NON-BLOCKING ask folds it in at its next turn boundary.
      # Either way the answer PERSISTS in the child\'s context. With no inline
      # answer, falls back to an interactive prompt (the ◆ takeover, like the
      # approval menu). Clears the blocked state and unblocks the tree.
      def handle_reply(arguments)
        tokens = arguments.to_s.strip.split(/\s+/)
        id     = tokens.shift
        if id.nil? || id.empty?
          show_blocked_agents
          return
        end

        # /reply is UNSCOPED: the human is the ultimate supervisor and may answer
        # ANY blocked node — one waiting on the human (:blocked_on_human) OR one
        # waiting on its agent-parent (:blocked_on_parent), if the human chooses
        # to step in.
        entry = Tools::BackgroundTasks.instance.find(id)
        if entry.nil? || !%i[blocked_on_human blocked_on_parent].include?(entry.status)
          @ui.error("#{id} is not waiting on you.")
          return
        end

        answer = dequote(tokens.join(" "))
        answer = prompt_reply_answer(entry) if answer.to_s.strip.empty?
        if answer.to_s.strip.empty?
          @ui.info("No answer given — #{id} is still waiting.")
          return
        end

        deliver_reply(entry, answer)
      end

      # The interactive ◆ takeover for /reply with no inline answer — mirrors the
      # approval menu (composer-suspend, ◆ glyph) so answering an ask_parent feels
      # exactly like answering an approval, a pattern the user already knows.
      def prompt_reply_answer(entry)
        @ui.info("")
        @ui.info("◆ #{entry.id} (#{entry.subagent}) asks — everything is waiting on this")
        @ui.info("   ❓ #{entry.ask_question}")
        @ui.ask("✎ your answer › ").to_s
      end

      # Routes the answer back DOWN to the child: decide the gate (unblocks a
      # blocking ask with the answer as its tool result) and push it onto the
      # steer queue (a non-blocking ask folds it in next turn). Then clear the
      # blocked state and repaint so the ⛔ marker clears.
      def deliver_reply(entry, answer)
        # The ONE shared answer wire (also used by the model-callable
        # answer_child tool): decide the gate + push the steer note + clear the
        # blocked state, all in BackgroundTasks#deliver_answer.
        Tools::BackgroundTasks.instance.deliver_answer(entry.id, answer)
        @ui.info("↳ answered #{entry.id}: #{truncate(answer, 80)}")
        @ui.info("✓ tree unblocked · #{entry.id} resumes at its next turn")
        @ui.set_subagent_cards if @ui.respond_to?(:set_subagent_cards)
      end

      # Lists the children currently blocked on the human (the /reply with no id
      # case) so the user can see who is waiting and on what.
      def show_blocked_agents
        blocked = Tools::BackgroundTasks.instance.awaiting_human
        if blocked.empty?
          @ui.info("No subagent is waiting on you.")
          return
        end

        @ui.info(pastel.red("⛔ #{blocked.size} subagent waiting on you:"))
        blocked.each do |e|
          @ui.info("  #{e.id} · #{e.subagent}: #{truncate(e.ask_question, 80)}")
        end
        @ui.info("/reply <id> <answer> to answer")
      end

      # Strips a single pair of wrapping double/single quotes from a steer/probe
      # argument so `steer "be terse"` lands as `be terse`, not `"be terse"`.
      def dequote(text)
        t = text.to_s.strip
        if t.length >= 2 && ((t.start_with?(%(")) && t.end_with?(%("))) || (t.start_with?("'") && t.end_with?("'")))
          return t[1..-2]
        end

        t
      end

      def show_agents_list
        entries = Tools::BackgroundTasks.instance.list
        if entries.empty?
          @ui.info("No background subagents. The agent starts them with its `task` tool;")
          @ui.info("they run while you keep working. They'll appear here when it does.")
          return
        end

        rows = entries.map do |e|
          [e.id, agent_status_icon(e.status), agent_label(e), agent_elapsed(e)]
        end
        @ui.table(headers: %w[ID Status Task Elapsed], rows: rows)
        @ui.info("/agents <id> for output   ·   /agents <id> --stop to cancel")
      end

      def show_agent_detail(id)
        entry = Tools::BackgroundTasks.instance.find(id)
        unless entry
          @ui.error("no background subagent with id #{id}.")
          return
        end

        case entry.status
        when :needs_approval
          # Option 2: a parked child is waiting on THIS human. Lead with the
          # interactive approve/deny prompt that resolves its gate.
          resolve_agent_approval(entry)
        when :running
          # #71 live drill-in: expand to the task summary + the recent-activity
          # ring, tailing the registry live until the user stops watching.
          watch_agent(entry)
        else
          show_agent_result(entry)
        end
      end

      # Static detail for a finished (done/failed) task — the full result/error,
      # as before.
      def show_agent_result(entry)
        @ui.info("#{entry.id}  #{agent_status_icon(entry.status)}  ·  #{entry.subagent}")
        @ui.info("task: #{truncate(entry.prompt, 200)}")
        @ui.separator
        case entry.status
        when :failed
          @ui.error(entry.error.to_s.empty? ? "(failed, no error message)" : entry.error.to_s)
        when :stopped
          show_stopped_summary(entry)
        else
          render_agent_report(entry.result.to_s)
        end
      end

      # The child's final report is markdown (it is a model answer): render it
      # through the SAME pipeline assistant answers use instead of dumping
      # literal `##`/`**` into the transcript (#139). Adapters without the
      # markdown seam (Null/API) keep the plain info fallback.
      def render_agent_report(result)
        return @ui.info("(no output)") if result.empty?

        if @ui.respond_to?(:commit_markdown_block)
          @ui.commit_markdown_block(result)
        else
          @ui.info(result)
        end
      end

      # A stopped child may have COMPLETED side effects before the stop (#150):
      # "no result" alone led the parent/human to assert nothing was produced
      # while an approved write was already on disk. Surface the tool count and
      # the registry's activity tail as ground truth.
      def show_stopped_summary(entry)
        count = entry.tool_count.to_i
        if count.zero?
          @ui.info("(stopped at your request before it ran any tools — no result)")
        else
          @ui.info("(stopped at your request after #{count} tool#{"s" if count != 1} had already run — " \
                   "completed tools' side effects may exist)")
          Array(entry.activity_log).last(3).each { |line| @ui.info("  #{line}") }
        end
      end

      # #71 — LIVE drill-in for a running subagent. Renders the task summary and
      # the recent-activity ring (read live from the registry, which the child's
      # UI::SubagentView keeps fresh), refreshing in place until the user presses a
      # key (Esc/Enter/q) or the task ends. Off an interactive terminal (#ask
      # returns nil — Null/API/pipe) it degrades to a SINGLE snapshot so the
      # non-interactive paths and unit tests never block on a redraw loop.
      def watch_agent(entry)
        render_agent_watch(entry)
        return unless interactive_terminal?

        @ui.info("(watching live — press Enter/Esc to stop, /agents #{entry.id} --stop to cancel)")
        watch_loop(entry.id)
      end

      # Renders ONE watch frame: header + task + the recent: ring. Public-ish
      # snapshot shape reused per refresh tick. The recent ring is the registry's
      # bounded activity_log, plus the live last_activity as the trailing ● line.
      def render_agent_watch(entry)
        @ui.info("#{entry.id}  #{agent_status_icon(entry.status)}  ·  #{entry.subagent}  ·  #{agent_elapsed(entry)}")
        @ui.info("task: #{truncate(entry.prompt, 120)}")
        @ui.info("recent:")
        Array(entry.activity_log).last(5).each { |line| @ui.info("  #{line}") }
        last = entry.last_activity.to_s
        @ui.info("  #{pastel.yellow("●")} #{last}") unless last.empty?
      end

      # The live refresh loop for #watch_agent. Polls the registry and re-renders
      # a frame each tick until the task leaves :running or the user hits a key.
      # Kept deliberately simple (a periodic re-render of the snapshot, not a
      # full-screen redraw) to stay scroll-native and avoid a second raw-mode
      # rendering subsystem. Bounded so it can never hang the REPL.
      def watch_loop(id, ticks: 600, interval: 0.5)
        ticks.times do
          break if key_pressed?(interval)

          entry = Tools::BackgroundTasks.instance.find(id)
          break if entry.nil? || entry.status != :running

          @ui.separator
          render_agent_watch(entry)
        end
        final = Tools::BackgroundTasks.instance.find(id)
        @ui.info("(stopped watching #{id})") if final && final.status == :running
      end

      # Option 2 — resolve a parked child's approval. Shows the command and asks
      # Approve once / Approve always / Deny; the answer resolves the child's
      # gate (the child's #confirm returns it). "always" approves AND persists via
      # the parent CLI's allowlist (the same path an inline approval uses), so the
      # child — and future calls — proceed without re-prompting.
      def resolve_agent_approval(entry)
        gate = entry.approval_gate
        unless gate
          @ui.info("#{entry.id} is no longer waiting on approval.")
          return
        end

        @ui.info("#{entry.id}  #{agent_status_icon(entry.status)}  ·  #{entry.subagent}")
        @ui.info("needs approval to run:")
        @ui.info("  #{entry.approval_command.to_s.empty? ? entry.approval_question : entry.approval_command}")
        answer = ask_approval_answer(entry)
        return if answer.nil?

        decision =
          case answer
          when "a", "always"      then persist_agent_always(entry)
                                       true
          when "o", "once", "y"   then true
          else                         false
          end
        gate.decide(entry.approval_id, decision)
        @ui.info(decision ? "Approved #{entry.id}." : "Denied #{entry.id}.")
      end

      # Reads the approval answer, re-rendering the prompt on an EMPTY read.
      # A background event (another child's completion fold-in) landing while
      # the prompt is open can abort the underlying TTY read, which used to
      # surface as an empty answer and silently resolve the gate to DENIED
      # (#144). An empty/aborted read is therefore never an answer: re-ask,
      # and after APPROVAL_ASK_ATTEMPTS empty reads return nil WITHOUT
      # touching the gate — the child stays parked and `/agents <id>`
      # re-opens the prompt. Denying requires an explicit keypress ("n", or
      # any other non-approving answer).
      def ask_approval_answer(entry)
        APPROVAL_ASK_ATTEMPTS.times do
          answer = @ui.ask("Approve? [o]nce / [a]lways / [n]o deny: ").to_s.strip.downcase
          return answer unless answer.empty?
        end
        @ui.info("no answer read — #{entry.id} is still waiting; /agents #{entry.id} to decide.")
        nil
      end

      # Persists an "approve always" for a parked subagent's command via the same
      # session allowlist the inline CLI approval uses, so the decision survives
      # and future identical calls (parent or child) skip the prompt.
      def persist_agent_always(entry)
        scope = "#{entry.subagent}:#{entry.approval_command}"
        Run::SessionApprovalCache.instance.remember(@ui.respond_to?(:session_id) ? @ui.session_id : nil, scope,
                                                    "session")
      rescue StandardError
        nil
      end

      # True when the REPL owns a real interactive terminal (so a live watch /
      # keypress poll makes sense). Off a TTY we render a single snapshot.
      def interactive_terminal?
        $stdin.respond_to?(:tty?) && $stdin.tty? && $stdout.respond_to?(:tty?) && $stdout.tty?
      rescue StandardError
        false
      end

      # Non-blocking-ish single-key poll: waits up to +timeout+s for any key.
      # Used to let the user stop the live watch with a keypress. Best-effort:
      # returns false (keep watching) on any terminal hiccup so the bounded loop
      # still terminates on its tick budget.
      def key_pressed?(timeout)
        return false unless interactive_terminal?

        ready = $stdin.wait_readable(timeout)
        return false unless ready

        $stdin.read_nonblock(1)
        true
      rescue StandardError
        false
      end

      def stop_agent(id)
        registry = Tools::BackgroundTasks.instance
        entry    = registry.find(id)
        unless entry
          @ui.error("no background subagent with id #{id}.")
          return
        end

        unless %i[running needs_approval blocked_on_human blocked_on_parent].include?(entry.status)
          @ui.info("#{id} already #{entry.status} — nothing to stop.")
          return
        end

        # A child parked on a human approval or an ask_parent is blocked in its
        # gate's wait; cancel the gates so it wakes (Interrupted → deny/cancel) and
        # unwinds instead of holding its thread until the bound. The stop-cascade
        # then wakes every DESCENDANT parked on a blocking ask too, so the whole
        # subtree unwinds at once (S5a — no orphaned blocked grandchild).
        # Mark the stop FIRST so the very next /agents list shows ◌ stopping
        # instead of a stale ● running (#108), and so the worker's terminal
        # write records the unwind as :stopped, not ✗ failed (#13) — then wake
        # the gates/runner.
        registry.request_stop(id)
        entry.approval_gate&.cancel!
        entry.ask_gate&.cancel!
        registry.cancel_descendant_ask_gates(id)
        entry.runner&.cancel!
        @ui.success("Stop requested for #{id} (#{entry.subagent}); it unwinds at its next checkpoint.")
      end

      # `<glyph> <word>` for a subagent's state, with a SPACE between glyph and
      # word and the glyph colored by state (#86): amber ● running, red ✗ failed,
      # green ✓ done — instead of a same-color, glued "●running".
      def agent_status_icon(status)
        glyph, word, color =
          case status
          when :running          then ["●", "running", :yellow]
          when :stopping         then ["◌", "stopping", :yellow]
          when :stopped          then ["⊘", "stopped", :yellow]
          when :needs_approval   then ["●", "approval", :yellow]
          when :blocked_on_human then ["⛔", "waiting on you", :red]
          when :blocked_on_parent then ["◷", "waiting on parent", :cyan]
          when :failed then ["✗", "failed", :red]
          else ["✓", "done", :green]
          end
        "#{pastel.public_send(color, glyph)} #{word}"
      end

      def pastel
        @pastel ||= Pastel.new
      end

      # subagent name + the DISTINGUISHING detail for the list label (#127). For
      # a running task the live last_activity is the most distinguishing field
      # (two "explore: summarize lib/…" tasks differ by what they're doing NOW),
      # so prefer it; otherwise a wider (80-char) slice of the prompt's first
      # line so the tail — often the distinguishing path/arg — survives instead
      # of being cut at 40.
      def agent_label(entry)
        if %i[running needs_approval stopping].include?(entry.status) && !entry.last_activity.to_s.empty?
          return "#{entry.subagent}: #{truncate(entry.last_activity, 80)}"
        end

        prompt = truncate_middle(entry.prompt.to_s.lines.first.to_s.strip, 80)
        prompt.empty? ? entry.subagent : "#{entry.subagent}: #{prompt}"
      end

      # Middle truncation for the /agents Task label (#14): similarly-phrased
      # delegations share their HEAD ("Summarize the contents of lib/…") while
      # the distinguishing detail — the path/arg — sits at the TAIL, so a
      # head-only cut renders concurrent tasks identical. Keep both ends,
      # elide the middle.
      def truncate_middle(text, max)
        s = text.to_s.gsub(/\s+/, " ").strip
        return s if s.length <= max

        head = (max - 1) * 2 / 3
        tail = max - 1 - head
        "#{s[0, head]}…#{s[-tail, tail]}"
      end

      def agent_elapsed(entry)
        finish = entry.finished_at || Time.now
        return "" unless entry.started_at

        human_duration(finish - entry.started_at)
      end

      def human_duration(seconds)
        secs = seconds.to_i
        return "#{secs}s" if secs < 60
        return "#{secs / 60}m" if secs < 3600

        "#{secs / 3600}h"
      end

      # --- /sessions ---------------------------------------------------------
      #
      # No-arg = list recent + how to resume; arg = resolve and resume in place.
      # Resuming returns a {resume_session_id:} signal the REPL acts on by
      # rebuilding its runner on that session (history replays). Reuses
      # Session::Repository#list and #find_by_id_or_title (which already raises
      # AmbiguousSessionError on >1 match).
      #
      # The management verbs (#183) reuse the CLI subcommands' logic
      # (CLI::SessionCommand.render / .destroy_with_confirm — ONE rendering and
      # ONE delete flow for both surfaces):
      #
      #   /sessions                → list (picker on a TTY) + resume
      #   /sessions --all          → list without the row cap
      #   /sessions show <id>      → details, without switching into it
      #   /sessions delete <id>    → delete (asks to confirm)
      #   /sessions <id|title>     → resume

      def handle_sessions(arguments)
        tokens = arguments.to_s.strip.split(/\s+/)
        all    = tokens.delete("--all") ? true : false
        return list_sessions(all: all) if tokens.empty?

        case tokens.first
        when "show"   then session_verb(tokens[1..].join(" "), "show") { |s| CLI::SessionCommand.render(s, ui: @ui) }
        when "delete" then session_verb(tokens[1..].join(" "), "delete") { |s| delete_session(s) }
        else resume_session(tokens.join(" "))
        end
      end

      # Resolves the id/title for a /sessions verb (same matcher resume uses,
      # so short ids and title substrings work) and yields the session row;
      # prints the usage/not-found/ambiguous error otherwise. Always :handled —
      # the verbs never fall through to the unknown-command path (#34).
      def session_verb(query, verb)
        if query.nil? || query.empty?
          @ui.info("Usage: /sessions #{verb} <id>")
          return :handled
        end

        session = Session::Repository.new.find_by_id_or_title(query)
        if session.nil?
          @ui.error("no session matching #{query.inspect}.")
          @ui.info("List them with /sessions")
        else
          yield session
        end
        :handled
      rescue Rubino::AmbiguousSessionError => e
        @ui.error(e.message)
        :handled
      end

      # Deletes a session in-chat via the SAME confirm-and-destroy flow the
      # `rubino sessions delete` CLI verb runs (#183). The session the live
      # runner sits on is refused — deleting the history under the active
      # runner would corrupt the running conversation; /new first.
      def delete_session(session)
        if @runner&.session&.dig(:id) == session[:id]
          @ui.error("that is the ACTIVE session — start a new one first (/new), then delete it.")
          return
        end

        CLI::SessionCommand.destroy_with_confirm(session, repo: Session::Repository.new, ui: @ui)
      end

      # `/probe <text>` — the discoverable alias for the `? ` prefix. Bare
      # `/probe` only teaches the prefix (the one-keystroke common case); with
      # text, signal the REPL to run the ephemeral side-inference and discard.
      def handle_probe(arguments)
        text = arguments.to_s.strip
        if text.empty?
          @ui.info("Ask an ephemeral side-question that is NOT saved to this session.")
          @ui.info("Tip: just start a line with '? ' — e.g.  ? is this lib MIT or GPL?")
          return :handled
        end

        { probe: text }
      end

      # `/branch [name]` — fork the current session here into a NEW saved one
      # and switch into it. The REPL holds the runner/session, so we just pass
      # the optional title along on the branch signal.
      def handle_branch(arguments)
        title = arguments.to_s.strip
        { branch: true, title: title.empty? ? nil : title }
      end

      def list_sessions(all: false)
        sessions = Session::Repository.new.list(limit: all ? nil : sessions_list_limit)
        if sessions.empty?
          @ui.info("No past sessions yet.")
          return :handled
        end

        # ONE surface, not two (#40): on a real terminal the arrow-key picker
        # IS the list (Enter resumes, Esc cancels — #73, letters filter), with
        # Created/Status folded into each row, so the same sessions are never
        # rendered twice (static table + picker). Off a TTY the static table +
        # typed-shortcut fallback renders instead.
        return sessions_table_fallback(sessions) unless interactive_terminal?

        choices = sessions.map { |s| [session_choice_label(s), s[:id]] }
        chosen  = @ui.select("Resume which session? (Esc to cancel)", choices)
        if chosen
          session = sessions.find { |s| s[:id] == chosen }
          @ui.success(%(Resuming #{chosen[0..7]}  "#{session_title(session)}")) if session
          return { resume_session_id: chosen }
        end

        @ui.info("Resume: /sessions <id|title>   ·   /sessions show|delete <id>")
        :handled
      end

      # Static fallback for non-interactive callers (pipes / Null UI): the
      # bordered table the picker replaces on a TTY. Leads with the identifying
      # fields (ID, Title, Created) so a narrow-term card fallback scans well —
      # the key field first, not buried (#84).
      def sessions_table_fallback(sessions)
        rows = sessions.map do |s|
          [s[:id].to_s[0..7], session_title(s), s[:created_at].to_s, s[:status].to_s, s[:message_count].to_s]
        end
        @ui.table(headers: %w[ID Title Created Status Msgs], rows: rows)
        @ui.info("Resume: /sessions <id|title>   ·   /sessions show|delete <id>")
        :handled
      end

      # One picker row: short id + title + message count + recency (and status
      # when not yet ended), so the highlighted entry is identifiable at a
      # glance and the picker is a clean superset of the old static table (#40).
      def session_choice_label(session)
        id    = session[:id].to_s[0..7]
        title = session_title(session)
        msgs  = session[:message_count]
        meta  = [
          ("#{msgs} msg#{"s" if msgs != 1}" if msgs),
          session_age(session),
          (session[:status].to_s unless ["", "ended"].include?(session[:status].to_s))
        ].compact.join(" · ")
        meta.empty? ? "#{id}  #{title}" : "#{id}  #{title}  (#{meta})"
      end

      # "Created" humanized for the picker row — "5m ago" scans better than a
      # raw ISO timestamp in a recency-ordered list (#40). nil when unparseable.
      def session_age(session)
        created = session[:created_at]
        created = Time.parse(created.to_s) unless created.is_a?(Time)
        "#{human_duration(Time.now - created)} ago"
      rescue StandardError
        nil
      end

      def resume_session(query)
        session = Session::Repository.new.find_by_id_or_title(query)
        if session.nil?
          @ui.error("no session matching #{query.inspect}.")
          @ui.info("List them with /sessions")
          return :handled
        end

        @ui.success(%(Resuming #{session[:id][0..7]}  "#{session_title(session)}"))
        { resume_session_id: session[:id] }
      rescue Rubino::AmbiguousSessionError => e
        @ui.error(e.message)
        :handled
      end

      def session_title(session)
        title = session[:title].to_s.strip
        title.empty? ? "(untitled)" : title
      end

      # The bare-list row cap (#183): configurable (`sessions.list_limit`) and
      # liftable per call with `/sessions --all` — no longer hardwired to 10.
      def sessions_list_limit
        limit = Rubino.configuration.dig("sessions", "list_limit").to_i
        limit.positive? ? limit : 10
      rescue StandardError
        10
      end

      # All known slash commands (built-ins + discovered custom), used for the
      # "Available:" hint on an unknown command (L6 — previously listed only
      # custom commands, which is usually empty).
      def available_commands
        custom = begin
          @loader.names
        rescue StandardError
          []
        end
        (BuiltIns::NAMES + custom).uniq
      end

      # The Built-in rows for /help, with synonyms collapsed so /help never
      # shows two rows that say the same thing (#87): /exit and /quit share one
      # "End session" row as "/exit, /quit". Everything else passes through in
      # the BuiltIns order.
      def help_builtin_rows
        rows = []
        seen = {}
        BuiltIns::DESCRIPTIONS.each do |name, desc|
          if (canonical = seen[desc])
            rows[canonical[:index]][0] = "#{canonical[:name]}, #{name}"
          else
            seen[desc] = { index: rows.length, name: name }
            rows << [name, desc]
          end
        end
        rows
      end

      def show_help
        @ui.info("Slash commands run actions or reusable prompts. Type /<name>; /help is this list.")
        @ui.blank_line
        @ui.info("Built-in:")
        rows  = help_builtin_rows
        width = rows.map { |name, _| name.length }.max
        rows.each do |name, desc|
          @ui.info("  #{name.ljust(width)}  - #{desc}")
        end
        @ui.blank_line

        # The `@` file-picker is a discoverable composer feature (type `@` to
        # autocomplete a workspace file) but was undocumented in /help (F14).
        # /paste and /clear-images already appear once under "Built-in" above,
        # so they're NOT repeated here — this section is image/file INPUT only,
        # no command rows (#87 de-dup).
        @ui.info("Input:")
        @ui.info("  ! <command>   - run a shell command yourself, no approval; output joins the context")
        @ui.info("  @<path>       - autocomplete a workspace file into the prompt")
        @ui.info("  @<image>      - attach an image (png/jpg/jpeg/gif/webp/bmp) to the turn")
        @ui.info("  <image path>  - drop or paste an image file path to attach it")
        @ui.blank_line

        # The keystroke vocabulary was invisible in /help (#87): a newcomer
        # couldn't learn how to cancel a turn, drive the approval menu, or that
        # Tab completes. One compact reference line covers it.
        @ui.info("Keys:")
        @ui.info("  ↑/↓ + Enter   - choose in the approval menu")
        @ui.info("  Enter         - send; during a turn, interrupt it and run this next")
        @ui.info("  Alt-Enter     - queue this to run after the current turn (or /queued <msg>)")
        @ui.info("  Shift-Tab     - cycle mode (default → plan → yolo)")
        @ui.info("  Ctrl-O        - reveal the last reasoning (collapsed or hidden)")
        @ui.info("  Ctrl-C        - cancel the turn (twice to exit)")
        @ui.info("  Tab           - complete the highlighted /command or @file")
        @ui.info("  /             - start a command;  @  attach a file/image")
        @ui.blank_line

        custom = @loader.all
        if custom.any?
          @ui.info("Custom commands  (run with /<name>; add --preview to see the prompt first):")
          custom.each do |cmd|
            @ui.info("  /#{cmd.name}#{custom_desc(cmd)}")
          end
        else
          @ui.info("Custom commands  (none yet — run /commands to learn how to add one)")
        end
      end

      def show_commands
        commands = @loader.all
        return explain_empty_commands if commands.empty?

        @ui.info("Custom commands  (run with /<name>; add --preview to see the prompt first):")
        commands.each do |cmd|
          @ui.info("  /#{cmd.name}#{custom_desc(cmd)}")
        end
      end

      # The cryptic old empty-state ("Add .md files to .rubino/commands/")
      # named a dir without ever explaining what a command IS. Now we explain
      # the concept, name the REAL configured paths, and show a concrete example.
      def explain_empty_commands
        @ui.info("Custom commands are reusable prompts you trigger with a slash. Each is a")
        @ui.info("Markdown file in a commands directory; the file body becomes the prompt")
        @ui.info("($ARGUMENTS / $1..$9 expand to what you type after the command).")
        @ui.blank_line
        @ui.info("No custom commands found yet.")
        @ui.blank_line
        @ui.info("Searched: #{command_dirs.join(", ")}")
        @ui.info("Create one, e.g. .rubino/commands/review.md:")
        @ui.blank_line
        @ui.info("    ---")
        @ui.info("    description: Review the current diff for bugs")
        @ui.info("    ---")
        @ui.info("    Review the staged diff. Flag correctness bugs only. $ARGUMENTS")
        @ui.blank_line
        @ui.info("Then run:  /review focus on the auth change")
      end

      # The directories the loader actually searches, for the empty-state copy.
      # Resolves through Loader.resolve_path so the "Searched:" line reports the
      # real paths (RUBINO_HOME-aware), not a literal ~/.rubino never searched.
      def command_dirs
        paths = Rubino.configuration.dig("commands", "paths")
        paths = Config::Defaults.to_hash.dig("commands", "paths") if paths.nil?
        Array(paths).map { |dir| Loader.resolve_path(dir) }
      rescue StandardError
        Loader.default_command_paths
      end

      # "  - <description>" suffix for a custom-command listing, omitted when the
      # command carries no description so the line stays clean.
      def custom_desc(cmd)
        desc = cmd.description.to_s.strip
        desc.empty? ? "" : "  - #{desc}"
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
          trust  = Rubino::Trust.trusted?(dir) ? "" : "  (untrusted — context/skills withheld)"
          @ui.info("  #{marker} #{dir}#{trust}")
        end
        @ui.info("Add more with /add-dir <path>")
      end

      # `/skills`                 → list (unchanged behavior).
      # `/skills <name>`          → ACTIVATE that skill for the session (sticky).
      #                             The name is validated against the registry; an
      #                             unknown OR DISABLED name errors and leaves the
      #                             active skill unchanged.
      # `/skills none`            → CLEAR the active skill (also the `✗ none`
      #                             picker entry, whose spliced label is
      #                             normalized here).
      # `/skills enable <name>`   → persistently re-enable a skill (#188) — the
      # `/skills disable <name>`    same StateRepository write the HTTP API
      #                             toggle and the `rubino skills` CLI verbs run
      #                             (Skills::Toggle), affecting EVERY session,
      #                             unlike the session-scoped activation.
      #
      # The active skill is stored in Rubino::ActiveSkill (a process-level slot,
      # mirroring Rubino::Modes) so it survives across turns and is force-loaded
      # into the system prompt each turn (Context::PromptAssembler).
      def handle_skills(arguments)
        tokens = arguments.to_s.strip.split(/\s+/)
        if SKILL_TOGGLE_VERBS.include?(tokens.first.to_s.downcase)
          toggle_skill(tokens[1], enabled: tokens.first.casecmp?("enable"))
          return
        end

        arg = normalize_skill_arg(arguments)

        return show_skills if arg.nil?

        if clear_skill_arg?(arg)
          previous = Rubino::ActiveSkill.current
          Rubino::ActiveSkill.clear
          if previous
            @ui.success("Cleared active skill (was: #{previous}).")
          else
            @ui.info("No active skill.")
          end
          return
        end

        # Trust-aligned discovery (#63): activate only skills the assembler
        # will actually pin — in an untrusted cwd a project-local skill is
        # refused (with a reason) instead of chip-active-but-not-injected.
        registry = Skills::Registry.trusted
        skill = registry.find(arg)
        unless skill
          if Skills::Registry.new.find(arg)
            @ui.error("skill #{arg} is in this directory's .rubino/skills, but the directory " \
                      "isn't trusted — its SKILL.md would not be loaded, so it can't be activated")
          else
            @ui.error("unknown skill: #{arg}")
            available = registry.names
            @ui.info("Available: #{available.join(", ")}") unless available.empty?
          end
          return
        end

        # A disabled skill is EXCLUDED from activation (#188): the assembler
        # refuses to inject it (active_skill_block checks enabled?), so pinning
        # it would show an active chip with no effect.
        unless registry.enabled?(skill.name)
          @ui.error("skill #{skill.name} is disabled — /skills enable #{skill.name} to use it")
          return
        end

        Rubino::ActiveSkill.set(skill.name)
        @ui.success("Active skill: #{skill.name} (loaded into context for this session).")
      end

      # `/skills enable|disable <name>` (#188) — the missing human surface for
      # the StateRepository toggle (previously HTTP-API-only). Persisted, so it
      # affects the Level-1 index of every session until toggled back.
      def toggle_skill(name, enabled:)
        verb = enabled ? "enable" : "disable"
        if name.to_s.strip.empty?
          @ui.info("Usage: /skills #{verb} <name>")
          return
        end

        registry = Skills::Registry.trusted
        unless Skills::Toggle.set(name, enabled: enabled, registry: registry)
          @ui.error("unknown skill: #{name}")
          available = registry.names
          @ui.info("Available: #{available.join(", ")}") unless available.empty?
          return
        end

        if enabled
          @ui.success("Enabled skill: #{name} (back in the skills index for every session).")
        else
          clear_disabled_active_skill(name)
          @ui.success("Disabled skill: #{name} (out of the index for every session; " \
                      "/skills enable #{name} to restore).")
        end
      end

      # Disabling the skill that is currently PINNED active would leave a lying
      # chip — the assembler silently drops a disabled active skill — so the
      # pin is cleared with a note instead.
      def clear_disabled_active_skill(name)
        return unless Rubino::ActiveSkill.current == name

        Rubino::ActiveSkill.clear
        @ui.info("(it was the active skill — pin cleared)")
      end

      # The single argument to `/skills`, trimmed; nil when no argument was
      # given (bare `/skills` → list). The picker splices the `✗ none` label, so
      # the leading `✗ ` marker is stripped here to recover the bare token.
      def normalize_skill_arg(arguments)
        raw = arguments.to_s.strip.sub(/\A✗\s+/, "")
        # Only the FIRST token is the skill name (skill names are single tokens).
        token = raw.split(/\s+/).first
        token unless token.nil? || token.empty?
      end

      # True when the argument means "clear the active skill" (the `none`
      # sentinel, case-insensitive — the `✗ ` marker was already stripped).
      def clear_skill_arg?(arg)
        arg.casecmp?(Rubino::ActiveSkill::NONE)
      end

      def show_skills
        registry = Skills::Registry.trusted
        skills = registry.all
        if skills.empty?
          @ui.info("No skills found.")
          @ui.info("Add .md files to .rubino/skills/ to create skills.")
        else
          active = Rubino::ActiveSkill.current
          skills.each do |skill|
            status = registry.enabled?(skill.name) ? "" : " (disabled)"
            status += " (active)" if active && active == skill.name
            head   = "  #{skill.name}#{status} - "
            # Word-wrap the description so a long one breaks on spaces instead of
            # being hard-wrapped mid-word by the terminal at the right edge
            # (B8 — "officia\nl"). Continuation lines hang-indent under the
            # description so the list stays readable.
            wrap_skill_line(head, skill.description.to_s).each { |line| @ui.info(line) }
          end
        end
      end

      # --- /mcp ----------------------------------------------------------------
      #
      # In-chat management of MCP servers (#182), shaped like /skills:
      #
      #   /mcp                 → server list: status, transport, tool count
      #   /mcp <server>        → drill-in: transport/target, health, its tools
      #   /mcp <server> off    → stop the client + deregister its tools (session)
      #   /mcp <server> on     → (re)start the client + register its tools
      #   /mcp reload          → re-read config.yml and reconnect every server
      #
      # List/drill-in read the LIVE booted manager (Rubino::MCP.manager) and
      # never re-spawn stdio servers — doctor's start/stop dance is wrong inside
      # a session that already holds clients. `off` is session-scoped, like
      # /skills activation; persistent disable stays a config edit (mcp.enabled
      # or removing the server).

      def handle_mcp(arguments)
        server, action = arguments.to_s.strip.split(/\s+/)
        # reload must work BEFORE the enabled? gate: its whole point is picking
        # up a config edit (e.g. a first server added mid-session).
        return reload_mcp if server == "reload"

        unless Rubino::MCP.enabled?
          show_mcp_empty_state
          return
        end

        server.nil? ? show_mcp_list : handle_mcp_server(server, action)
      end

      # The two empty states the issue calls out: no servers at all vs the
      # mcp.enabled kill switch.
      def show_mcp_empty_state
        if mcp_servers_config.any?
          @ui.info("MCP is disabled (mcp.enabled: false in config.yml) — " \
                   "#{mcp_servers_config.size} server(s) defined but not started.")
        else
          @ui.info("No MCP servers configured.")
          @ui.info("Add an mcp.servers block to config.yml (see docs/mcp.md), then /mcp reload.")
        end
      end

      def show_mcp_list
        mcp_servers_config.each do |name, server_config|
          tools = mcp_tools_for(name).size
          @ui.info("  #{name} (#{server_config["transport"] || "stdio"})  " \
                   "#{mcp_status_icon(name)}  ·  #{tools} tool#{"s" if tools != 1}")
        end
        @ui.info("/mcp <server> for its tools   ·   /mcp <server> on|off   ·   /mcp reload")
      end

      def handle_mcp_server(name, action)
        unless mcp_servers_config.key?(name)
          @ui.error("unknown MCP server: #{name}")
          @ui.info("Configured: #{mcp_servers_config.keys.join(", ")}")
          return
        end

        case action
        when nil   then show_mcp_server(name)
        when "off" then mcp_server_off(name)
        when "on"  then mcp_server_on(name)
        else
          @ui.error("unknown /mcp action: #{action}")
          @ui.info("Usage: /mcp #{name} [on|off]")
        end
      end

      def show_mcp_server(name)
        server_config = mcp_servers_config[name]
        transport     = server_config["transport"] || "stdio"
        target        = if transport == "stdio"
                          [server_config["command"], *Array(server_config["args"])].join(" ")
                        else
                          server_config["url"].to_s
                        end

        @ui.info("#{name}  #{mcp_status_icon(name)}")
        @ui.info("  transport  #{transport}  ·  #{target}")
        last_error = Rubino::MCP.manager&.last_errors&.dig(name)
        @ui.info("  last error #{last_error}") if last_error
        show_mcp_server_tools(name)
      end

      # The server's registered tools (prefixed names + descriptions), wrapped
      # like the /skills list so long descriptions never hard-break mid-word.
      def show_mcp_server_tools(name)
        tools = mcp_tools_for(name)
        if tools.empty?
          @ui.info("  tools      (none registered — /mcp #{name} on to start it)")
          return
        end

        @ui.info("  tools      #{tools.size}:")
        tools.each do |tool|
          wrap_skill_line("    #{tool.name} - ", tool.description.to_s).each { |line| @ui.info(line) }
        end
      end

      # Session-scoped disable: stop the client AND drop its wrappers from the
      # registry (Manager#stop_server deregisters — #182), so the model stops
      # seeing tools whose client is gone.
      def mcp_server_off(name)
        manager = Rubino::MCP.manager
        if manager.nil? || !manager.clients.key?(name)
          @ui.info("MCP server #{name} is not running.")
          return
        end

        removed = mcp_tools_for(name).size
        manager.stop_server(name)
        @ui.success("MCP server #{name} stopped — #{removed} tool#{"s" if removed != 1} removed " \
                    "for this session (/mcp #{name} on to restart; config untouched).")
      end

      # (Re)start one server and register its tools. With no booted manager yet
      # (MCP never enabled at boot, or boot failed), boot! brings the whole
      # subsystem up — which starts this server too.
      def mcp_server_on(name)
        manager = Rubino::MCP.manager || Rubino::MCP.boot!
        unless manager
          @ui.error("could not boot MCP — check mcp.servers in config.yml, or /mcp reload")
          return
        end

        manager.stop_server(name) if manager.clients.key?(name)
        # start_server already warned with the failure detail; just point at it.
        return @ui.error("could not start MCP server #{name} (see warning above)") unless
          manager.start_server(name, mcp_servers_config[name])

        manager.register_server_tools(name)
        count = mcp_tools_for(name).size
        @ui.success("MCP server #{name} started — #{count} tool#{"s" if count != 1} registered.")
      end

      def reload_mcp
        manager = Rubino::MCP.reload!
        if manager.nil?
          show_mcp_empty_state
          return
        end

        @ui.success("MCP reloaded.")
        show_mcp_list
      end

      # `<glyph> <word>` for a server's state (colored like agent_status_icon):
      # green ● reachable, red ✗ down, yellow ◌ not started (no live client).
      def mcp_status_icon(name)
        entry = mcp_health.find { |h| h[:name] == name }
        glyph, word, color =
          if entry.nil? then ["◌", "not started", :yellow]
          elsif entry[:alive] then ["●", "reachable", :green]
          else ["✗", "down", :red]
          end
        "#{pastel.public_send(color, glyph)} #{word}"
      end

      # The configured mcp.servers block (name => config), {} when absent.
      def mcp_servers_config
        Rubino.configuration.dig("mcp", "servers") || {}
      end

      # Live reachability from the booted manager; [] when MCP never booted.
      # Manager#health_check already rescues per client, so a wedged transport
      # reports alive: false instead of raising.
      def mcp_health
        Rubino::MCP.manager&.health_check || []
      end

      # The registry wrappers a server contributed (prefixed tools).
      def mcp_tools_for(server_name)
        Tools::Registry.all.select do |tool|
          tool.is_a?(Rubino::MCP::MCPToolWrapper) && tool.server_name == server_name
        end
      end

      # Wraps "<head><description>" to the terminal width, breaking only on
      # whitespace, with continuation lines indented to the description column.
      # A single word longer than the available width is left intact (better an
      # over-long line than a meaningless mid-word split).
      def wrap_skill_line(head, description)
        width = terminal_width
        indent = " " * head.length
        avail  = [width - head.length, 20].max

        lines = []
        current = +""
        description.split(/\s+/).each do |word|
          candidate = current.empty? ? word : "#{current} #{word}"
          if candidate.length > avail && !current.empty?
            lines << current
            current = word.dup
          else
            current = candidate
          end
        end
        lines << current unless current.empty?
        lines = [""] if lines.empty?

        lines.each_with_index.map { |line, i| (i.zero? ? head : indent) + line }
      end

      def truncate(text, max)
        s = text.to_s.gsub(/\s+/, " ").strip
        s.length > max ? "#{s[0, max - 1]}…" : s
      end

      def terminal_width
        cols = IO.console&.winsize&.last
        (cols && cols.positive? ? cols : 80)
      rescue StandardError
        80
      end
    end
  end
end
