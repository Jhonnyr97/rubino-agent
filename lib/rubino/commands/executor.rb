# frozen_string_literal: true

require "pastel"

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
          @ui.error("Unknown command: /#{name}")
          @ui.info("Available: #{available_commands.join(', ')}")
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
          show_skills
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
        when "status"
          show_status
          :handled
        when "memory"
          handle_memory(arguments)
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
        else
          nil
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
      rescue ArgumentError => e
        @ui.error(e.message)
        @ui.info("Available: #{Rubino::Modes::ALL.join(', ')}")
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
        @ui.info("  approvals  #{status_approvals_line}")
        @ui.info("  session    #{status_session_line}")
        @ui.info("  tools      #{status_tools_line}")
        @ui.info("  memory     #{status_memory_line}   (use /memory)")
        @ui.info("  skills     #{status_skills_line}   (use /skills)")
        @ui.info("  background #{status_background_line}   (use /agents)")
        @ui.separator
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

      def status_session_line
        session = @runner&.session
        return "(none)" unless session

        id    = session[:id].to_s[0..7]
        title = session[:title].to_s.strip
        title = title.empty? ? "(untitled)" : %("#{title}")
        msgs  = session[:message_count]
        "#{id}  #{title}#{msgs ? " · #{msgs} msgs" : ""}"
      end

      def status_memory_line
        store   = Memory::Store.new
        backend = Rubino.configuration.dig("memory", "backend") || Memory::Backends::DEFAULT_NAME
        "backend: #{backend} · #{store.count} facts"
      rescue StandardError
        "(unavailable)"
      end

      def status_skills_line
        registry = Skills::Registry.new
        all      = registry.all
        enabled  = all.count { |s| registry.enabled?(s.name) }
        "#{all.size} available, #{enabled} enabled"
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
      #   /memory               → backend + count + recent facts
      #   /memory <query>       → substring search over content
      #   /memory forget <id>   → delete a fact

      def handle_memory(arguments)
        args = arguments.to_s.strip

        if args.empty?
          show_memory_summary
        elsif args.match?(/\Aforget\b/)
          id = args[/\Aforget\s+(\S+)\z/, 1]
          id ? forget_memory(id) : @ui.info("Usage: /memory forget <id>")
        else
          search_memory(args)
        end
      end

      def show_memory_summary
        store    = memory_backend
        backend  = Rubino.configuration.dig("memory", "backend") || Memory::Backends::DEFAULT_NAME
        @ui.info("backend  #{backend}   ·   #{store.count} facts")

        memories = store.list(limit: 10)
        if memories.empty?
          @ui.info("No facts stored yet — the agent records them as it learns about you.")
          return
        end

        render_memory_table(memories)
        @ui.info("/memory <query>   ·   /memory forget <id>")
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
        @ui.info(%(#{shown.length} match#{'es' if shown.length != 1} for #{query.inspect}))
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
          @ui.error("No fact with id #{id}.")
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

      def render_memory_table(memories)
        rows = memories.map do |m|
          [m[:id].to_s[0..7], m[:kind].to_s, truncate(m[:content], 60)]
        end
        @ui.table(headers: %w[ID Kind Content], rows: rows)
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
          @ui.error(%(Usage: /agents #{id} steer "your note"))
          return
        end

        if Tools::BackgroundTasks.instance.steer(id, text)
          @ui.info("steer ▸ #{id} ← #{truncate(text, 80)}  (parked · enters child context next turn)")
          @ui.set_subagent_cards if @ui.respond_to?(:set_subagent_cards)
        else
          @ui.error("Cannot steer #{id} — no such running subagent.")
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
          @ui.error(%(Usage: /agents #{id} probe "your question"))
          return
        end

        entry = Tools::BackgroundTasks.instance.find(id)
        unless entry
          @ui.error("Cannot probe #{id} — no such subagent.")
          return
        end

        @ui.info(pastel.dim("┄┄ probe → #{id} ┄┄  (ephemeral · not saved · child trajectory unchanged)"))
        @ui.info("?  #{question}")
        answer = Tools::SubagentProbe.new.peek(entry: entry, question: question)
        @ui.info("⟵  #{answer}")
        @ui.info(pastel.dim("┄┄ end probe (nothing was saved to #{id}) ┄┄"))
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
        return t[1..-2] if t.length >= 2 && ((t.start_with?(%(")) && t.end_with?(%("))) || (t.start_with?("\'") && t.end_with?("\'")))

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
          @ui.error("No background subagent with id #{id}.")
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
        if entry.status == :failed
          @ui.error(entry.error.to_s.empty? ? "(failed, no error message)" : entry.error.to_s)
        else
          @ui.info(entry.result.to_s.empty? ? "(no output)" : entry.result.to_s)
        end
      end

      # #71 — LIVE drill-in for a running subagent. Renders the task summary and
      # the recent-activity ring (read live from the registry, which the child's
      # EventBus tap keeps fresh), refreshing in place until the user presses a
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
        @ui.info("  #{pastel.yellow('●')} #{last}") unless last.empty?
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
        answer = @ui.ask("Approve? [o]nce / [a]lways / [N]o deny: ").to_s.strip.downcase

        decision =
          case answer
          when "a", "always"      then persist_agent_always(entry); true
          when "o", "once", "y"   then true
          else                         false
          end
        gate.decide(entry.approval_id, decision)
        @ui.info(decision ? "Approved #{entry.id}." : "Denied #{entry.id}.")
      end

      # Persists an "approve always" for a parked subagent's command via the same
      # session allowlist the inline CLI approval uses, so the decision survives
      # and future identical calls (parent or child) skip the prompt.
      def persist_agent_always(entry)
        scope = "#{entry.subagent}:#{entry.approval_command}"
        Run::SessionApprovalCache.instance.remember(@ui.respond_to?(:session_id) ? @ui.session_id : nil, scope, "session")
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
          @ui.error("No background subagent with id #{id}.")
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
          when :running          then ["●", "running",        :yellow]
          when :needs_approval   then ["●", "approval",        :yellow]
          when :blocked_on_human then ["⛔", "waiting on you",   :red]
          when :blocked_on_parent then ["◷", "waiting on parent", :cyan]
          when :failed           then ["✗", "failed",          :red]
          else                        ["✓", "done",            :green]
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
        if %i[running needs_approval].include?(entry.status) && !entry.last_activity.to_s.empty?
          return "#{entry.subagent}: #{truncate(entry.last_activity, 80)}"
        end

        prompt = truncate(entry.prompt.to_s.lines.first.to_s.strip, 80)
        prompt.empty? ? entry.subagent : "#{entry.subagent}: #{prompt}"
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

      def handle_sessions(arguments)
        query = arguments.to_s.strip
        return list_sessions if query.empty?

        resume_session(query)
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

      def list_sessions
        sessions = Session::Repository.new.list(limit: 10)
        if sessions.empty?
          @ui.info("No past sessions yet.")
          return :handled
        end

        # Lead with the identifying fields (ID, Title, Created) so a narrow-term
        # card fallback scans well — the key field first, not buried (#84).
        rows = sessions.map do |s|
          [s[:id].to_s[0..7], session_title(s), s[:created_at].to_s, s[:status].to_s, s[:message_count].to_s]
        end
        @ui.table(headers: %w[ID Title Created Status Msgs], rows: rows)

        # "resume one" should actually let you pick one: offer an arrow-key
        # picker over the listed sessions (reusing the approval-menu component
        # via @ui.select), Enter resumes the highlighted session, Esc cancels
        # (#145). Off a real terminal @ui.select returns nil and we keep the
        # static-table + typed-shortcut behaviour.
        choices = sessions.map { |s| [session_choice_label(s), s[:id]] }
        chosen  = @ui.select("Resume which session? (Esc to cancel)", choices)
        if chosen
          session = sessions.find { |s| s[:id] == chosen }
          @ui.success(%(Resuming #{chosen[0..7]}  "#{session_title(session)}")) if session
          return { resume_session_id: chosen }
        end

        @ui.info("Resume: /sessions <id|title>  (or run /sessions and pick from the menu)")
        :handled
      end

      # One picker row: short id + title + message count, so the highlighted
      # entry is identifiable at a glance in the arrow-key menu.
      def session_choice_label(session)
        id    = session[:id].to_s[0..7]
        title = session_title(session)
        msgs  = session[:message_count]
        "#{id}  #{title}#{msgs ? "  (#{msgs} msg#{'s' if msgs != 1})" : ""}"
      end

      def resume_session(query)
        session = Session::Repository.new.find_by_id_or_title(query)
        if session.nil?
          @ui.error("No session matching #{query.inspect}.")
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

      # All known slash commands (built-ins + discovered custom), used for the
      # "Available:" hint on an unknown command (L6 — previously listed only
      # custom commands, which is usually empty).
      def available_commands
        custom = @loader.names rescue []
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
        @ui.info("  @<path>       - autocomplete a workspace file into the prompt")
        @ui.info("  @<image>      - attach an image (png/jpg/jpeg/gif/webp/bmp) to the turn")
        @ui.info("  <image path>  - drop or paste an image file path to attach it")
        @ui.blank_line

        # The keystroke vocabulary was invisible in /help (#87): a newcomer
        # couldn't learn how to cancel a turn, drive the approval menu, or that
        # Tab completes. One compact reference line covers it.
        @ui.info("Keys:")
        @ui.info("  ↑/↓ + Enter   - choose in the approval menu")
        @ui.info("  Enter         - send (or inject mid-turn)")
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
        @ui.info("Searched: #{command_dirs.join(', ')}")
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

      def show_skills
        registry = Skills::Registry.new
        skills = registry.all
        if skills.empty?
          @ui.info("No skills found.")
          @ui.info("Add .md files to .rubino/skills/ to create skills.")
        else
          skills.each do |skill|
            status = registry.enabled?(skill.name) ? "" : " (disabled)"
            head   = "  #{skill.name}#{status} - "
            # Word-wrap the description so a long one breaks on spaces instead of
            # being hard-wrapped mid-word by the terminal at the right edge
            # (B8 — "officia\nl"). Continuation lines hang-indent under the
            # description so the list stays readable.
            wrap_skill_line(head, skill.description.to_s).each { |line| @ui.info(line) }
          end
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
