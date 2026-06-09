# frozen_string_literal: true

module Rubino
  module Tools
    # Delegates a bounded sub-task to a specialized subagent (the "agents-as-tools"
    # pattern). Modeled on Claude Code's Task/Agent tool, which runs subagents in
    # the BACKGROUND via `run_in_background` — here background is the DEFAULT:
    #
    #   - background (default): spawn the subagent on its own thread and return
    #     IMMEDIATELY with a task id (`sa_…`). The subagent works while the parent
    #     keeps going. On completion the parent is NOTIFIED — a `[background-task]`
    #     message is injected into its live turn (via the parent's InputQueue, the
    #     same channel mid-turn steering uses) — and the result is also fetchable
    #     with `task_result(<id>)` or stoppable with `task_stop(<id>)`. This is
    #     the SendMessage/poll/notify trio Claude Code exposes for background
    #     agents, mapped onto the gem's existing async substrate.
    #   - synchronous (`background: false`): the legacy path — run the nested turn
    #     to completion inline and return ONLY the subagent's final message as the
    #     tool result. For callers that cannot proceed without the answer now.
    #
    # Isolation contract (unchanged, both paths):
    #   - the nested run gets a FRESH session seeded with ONLY the `prompt`
    #     string — the parent transcript never leaks into the child;
    #   - each background child gets its OWN Interaction::EventBus (like
    #     Run::Executor does per top-level run) so its tool events never pollute
    #     the parent recorder;
    #   - the only parent→child channel is the `prompt`, so the parent model must
    #     put any needed file paths / errors into it.
    #
    # Scoped nesting (S1): a subagent CAN now spawn its own subagents (the
    # delegation tools are no longer stripped from a subagent's tool list). The
    # tree is bounded in ONE place — BackgroundTasks#reserve — by three caps:
    # max nesting depth (tasks.max_depth), per-owner live children
    # (tasks.max_children_per_node), and a global live ceiling
    # (tasks.max_concurrent_total). When a cap is hit reserve returns nil and this
    # tool surfaces a clear, reason-specific message (#capacity_message) so the
    # model knows whether to retry later, do the work inline, or report back.
    class TaskTool < Base
      # Suffix of the placeholder a subagent run lands on when it produced no
      # final assistant text — a no-op or a fully-denied run (every tool denied,
      # nothing said). Used as the single signal that a completion was a no-op so
      # both the background completion line and the foreground delegation row can
      # show a neutral indicator instead of a misleading green ✓ (#16).
      NOOP_RESULT_SUFFIX = "returned no output)"

      # True when a subagent's final result text is the no-op placeholder, i.e.
      # the run did nothing / was denied. Shared by completion_summary so the
      # background path mirrors the foreground delegation row.
      def self.noop_result?(text)
        text.to_s.strip.end_with?(NOOP_RESULT_SUFFIX)
      end

      def name
        "task"
      end

      # `task` is the config gate; absent from config ⇒ enabled (opt-out model),
      # same as every other tool.
      def config_key
        "task"
      end

      def description
        "Delegate a bounded sub-task to a specialized subagent. By DEFAULT the " \
        "subagent runs in the BACKGROUND: this call returns immediately with a " \
        "task id and the subagent keeps working while you continue with other " \
        "tools or reasoning — do NOT wait for it. When it finishes you will " \
        "automatically receive a `[background-task] <id> completed` message with " \
        "its result; you can also fetch the result anytime with `task_result(<id>)` " \
        "or stop it with `task_stop(<id>)`. Set `background: false` ONLY when you " \
        "cannot proceed without the subagent's answer in this same step (this " \
        "blocks until it finishes and returns the result inline). The subagent " \
        "runs in an isolated fresh context (it does NOT see this conversation) and " \
        "returns only its final message — put every file path / error / detail it " \
        "needs into `prompt`. Available subagents: #{available_subagents_description}."
      end

      def input_schema
        {
          type: "object",
          properties: {
            subagent: { type: "string", description: "Name of the subagent to delegate to (#{available_subagent_names.join(', ')})" },
            prompt:   { type: "string", description: "The full self-contained task for the subagent (the only context it receives)" },
            background: {
              type: "boolean",
              description: "Run the subagent in the background (default true). " \
                           "true = return immediately with a task id, keep working, get " \
                           "notified on completion. false = block until the subagent " \
                           "finishes and return its result inline."
            }
          },
          required: %w[subagent prompt]
        }
      end

      # Spawns a gated nested run, not a destructive op — the nested tools carry
      # their own approval/risk gates. Low risk keeps it auto-available so the
      # model can auto-delegate from the description.
      def risk_level
        :low
      end

      def call(arguments)
        subagent   = (arguments["subagent"] || arguments[:subagent]).to_s.strip
        prompt     = (arguments["prompt"]   || arguments[:prompt]).to_s
        background = background_arg(arguments)

        return "Error: subagent is required" if subagent.empty?
        return "Error: prompt is required"   if prompt.strip.empty?

        definition = registry.find(subagent)
        unless definition&.subagent?
          return "Error: unknown subagent '#{subagent}'. " \
                 "Valid subagents: #{available_subagent_names.join(', ')}."
        end

        if background
          run_background(definition, prompt)
        else
          run_subagent(definition, prompt)
        end
      rescue StandardError => e
        "Error: subagent '#{subagent}' failed: #{e.message}"
      end

      private

      # background defaults to TRUE (Claude-Code-style background-by-default).
      # Absent ⇒ true; only an explicit false (bool or "false") opts into the
      # synchronous path. A nil from a caller that omitted the key stays true.
      def background_arg(arguments)
        raw = arguments.key?("background") ? arguments["background"] : arguments[:background]
        return true if raw.nil?

        ![false, "false", 0, "0"].include?(raw)
      end

      # Background spawn (the default). Reserves a registry slot, builds the
      # child Runner with its OWN EventBus (isolation), launches it on a thread,
      # and returns a handle string IMMEDIATELY — the parent never blocks.
      #
      # On completion the worker's `ensure` records terminal state, emits a
      # SUBAGENT_COMPLETED/FAILED event (so the CLI/web can surface it), and
      # pushes a `[background-task]` notice onto the captured parent sink (the
      # parent's InputQueue) so the parent folds the result in at its next
      # iteration boundary — the Claude Code "auto-notify on completion" contract.
      def run_background(definition, prompt)
        registry_bg = BackgroundTasks.instance
        # Ownership link (S1): when THIS run is itself a subagent, the thread-local
        # current-subagent id is the spawner — the new child's owner. nil ⇒ the
        # human / top-level agent is spawning (depth 0). The owner's depth is what
        # reserve uses to stamp the child (owner.depth + 1); we pass 0 only as the
        # human-spawned default. reserve recomputes depth from the owner entry, so
        # this is just the top-level base case.
        owner_id = Rubino.current_subagent_id
        entry = registry_bg.reserve(
          subagent: definition.name, prompt: prompt,
          owner_subagent_id: owner_id, depth: 0
        )
        return capacity_message(registry_bg) unless entry

        # Captured on the PARENT thread, before we spawn — the child thread has
        # no access to the parent's thread-locals. The sink is the parent's
        # InputQueue (completion notice), event_bus is the turn-scoped bus (so
        # SSE/recorder sees the lifecycle), parent_ui is the parent's CLI view
        # (so completion surfaces as a line, like background-shell does).
        sink      = Rubino.background_sink
        event_bus = Rubino.active_event_bus
        parent_ui = Rubino.ui
        # Build the child UI on the PARENT thread so the collapsed-card view is
        # wired with this run's entry id + the parent CLI (whose live region hosts
        # the card) + the approval handler. In card mode the child's per-tool
        # activity feeds the registry instead of flooding $stdout (#124).
        child_ui  = nested_ui_for(entry, parent_ui)
        runner    = build_background_runner(definition, child_ui)

        thread = Thread.new do
          run_child_thread(entry, runner, prompt, sink, event_bus, parent_ui, child_ui)
        end
        registry_bg.attach(entry, thread: thread, runner: runner)

        event_bus&.emit(Interaction::Events::SUBAGENT_SPAWNED,
                        task_id: entry.id, subagent: definition.name,
                        prompt: truncate(prompt, 200))
        # Paint the collapsed card for this just-spawned subagent immediately so
        # it shows "running · 0 tools" the instant delegation starts, not only
        # after its first child tool fires.
        repaint_parent_cards(parent_ui)

        spawn_handle(entry, definition)
      end

      # The child worker body. Runs the nested loop under the child UI, then —
      # ALWAYS, even on a child exception (Exception net like Run::Executor) —
      # records terminal state, notifies the parent, and emits the lifecycle
      # event. A child LoadError/SyntaxError must not wedge the task as
      # "running" forever.
      def run_child_thread(entry, runner, prompt, sink, event_bus, parent_ui, child_ui = nil)
        # The runner already renders through the card-mode child UI (wired at
        # spawn); with_ui binds that SAME instance thread-locally so any global
        # Rubino.ui lookup inside the nested loop also resolves to it.
        ui_for_child = child_ui || nested_ui_for(entry, parent_ui)
        # Wire the child Loop with the entry's OWN steering queue (parent->child
        # `steer` channel) and bind the current-subagent id so a tool the child
        # invokes (ask_parent) can find its own registry entry. The steer queue
        # is the SAME InputQueue the human uses to steer the parent: the parent
        # pushes a note via BackgroundTasks#steer, the child folds it in at its
        # next iteration boundary (Loop#inject_steered_input).
        result = Rubino.with_current_subagent_id(entry.id) do
          Rubino.with_ui(ui_for_child) do
            runner.run!(prompt, input_queue: entry.steer_queue)
          end
        end
        text     = result.to_s.strip
        text     = "(subagent '#{entry.subagent}' #{NOOP_RESULT_SUFFIX}" if text.empty?

        BackgroundTasks.instance.complete(entry, status: :completed, result: text)
        notify(sink, completion_notice(entry, text))
        surface_completion(parent_ui, completion_summary(entry, text))
        repaint_parent_cards(parent_ui)
        event_bus&.emit(Interaction::Events::SUBAGENT_COMPLETED,
                        task_id: entry.id, subagent: entry.subagent,
                        status: "completed", output: truncate(text, 400))
      rescue Exception => e # rubocop:disable Lint/RescueException
        BackgroundTasks.instance.complete(entry, status: :failed, error: e.message)
        notify(sink, failure_notice(entry, e.message))
        surface_completion(parent_ui, "✗ #{entry.id} · #{entry.subagent} · failed: #{e.message}")
        repaint_parent_cards(parent_ui)
        event_bus&.emit(Interaction::Events::SUBAGENT_FAILED,
                        task_id: entry.id, subagent: entry.subagent,
                        status: "failed", error: e.message)
      end

      # One committed summary line for a finished subagent, folded above the
      # prompt by #surface_completion (the card itself clears when the registry
      # snapshot no longer lists it as running). Mirrors the blueprint's
      # `✓ sa_… · explore · done · 47s · 18 tools — <result head>`.
      # The glyph reflects the OUTCOME: a genuine completion shows ✓, while a
      # no-op / fully-denied run (final text is the no-op placeholder) shows a
      # neutral ⊘ "no-op" instead — a denied subagent that did nothing must not
      # read as a success (#16). The error path renders ✗ in #run_child_thread.
      def completion_summary(entry, text)
        count = entry.tool_count.to_i
        head  = truncate(text.lines.first.to_s.strip, 80)
        if self.class.noop_result?(text)
          "⊘ #{entry.id} · #{entry.subagent} · no-op · #{count} tools — #{head}"
        else
          "✓ #{entry.id} · #{entry.subagent} · done · #{count} tools — #{head}"
        end
      end

      # Repaints the parent's collapsed card block from the registry snapshot.
      # Best-effort: cosmetic, never breaks the worker. No-op off the CLI.
      def repaint_parent_cards(parent_ui)
        parent_ui.set_subagent_cards if parent_ui.respond_to?(:set_subagent_cards)
      rescue StandardError
        nil
      end

      # Renders a one-line completion notice on the parent's CLI view, parallel
      # to how a background shell's exit surfaces. DISPLAY-ONLY (a note on the
      # parent UI) — the authoritative delivery to the MODEL is the InputQueue
      # notice + the registry. No-op on Null/API (note is a quiet annotation).
      def surface_completion(parent_ui, line)
        parent_ui&.note(line) if parent_ui.is_a?(UI::CLI)
      rescue StandardError
        # A UI hiccup must never wedge the worker's terminal-state bookkeeping.
      end

      # Pushes the notice onto the parent's InputQueue if one is wired. The
      # parent loop drains it at its next iteration top (Loop#inject_steered_input)
      # — between turns, never between a tool_use and its results. When no sink
      # exists (API/server, or the parent turn already ended) the result still
      # lives in the registry and is reachable via `task_result`.
      def notify(sink, text)
        sink&.push(text)
      end

      def completion_notice(entry, text)
        "[background-task] Task #{entry.id} (subagent '#{entry.subagent}') completed.\n" \
        "Result:\n#{truncate(text, 4000)}\n" \
        "(full result via task_result(\"#{entry.id}\"))"
      end

      def failure_notice(entry, message)
        "[background-task] Task #{entry.id} (subagent '#{entry.subagent}') failed: #{message}"
      end

      def spawn_handle(entry, definition)
        "Started background subagent '#{definition.name}' as task #{entry.id}. " \
        "It is running now — keep working on other things. You'll receive a " \
        "`[background-task]` message when it finishes; or call " \
        "task_result(\"#{entry.id}\") to check on it, task_stop(\"#{entry.id}\") to cancel."
      end

      # Turns a nil reserve into a clear, reason-specific model-facing string. The
      # registry records WHY it refused (last_refusal_reason) so the three caps —
      # max nesting depth, per-owner fan-out, global total — read distinctly
      # instead of one undifferentiated "at capacity".
      def capacity_message(registry_bg)
        case registry_bg.last_refusal_reason
        when :depth
          "Max nesting depth reached: subagents can only nest #{BackgroundTasks::MAX_DEPTH} " \
          "levels deep. This subagent is too deep to delegate further — do the work " \
          "directly, or report back so a shallower agent can split it up."
        when :per_owner
          "At capacity: this agent already has #{BackgroundTasks::MAX_CHILDREN_PER_NODE} " \
          "background subagents running. Wait for one to finish (you'll get a " \
          "`[background-task]` message), check it with task_result, or run this one " \
          "with background: false."
        else # :global (or any future ceiling)
          "At capacity: the maximum number of background subagents " \
          "(#{BackgroundTasks::MAX_CONCURRENT_TOTAL}) are already running across all " \
          "agents. Wait for one to finish (you'll get a `[background-task]` message), " \
          "check it with task_result, or run this one with background: false."
        end
      end

      # Background children get their OWN fresh EventBus so their inner tool
      # events stay off the parent recorder (the result-only isolation contract).
      # Built directly here (not via @runner_factory, which tests use to inject a
      # stub for the SYNC path) so the bus wiring is always honored.
      def build_background_runner(definition, child_ui)
        if @runner_factory
          @runner_factory.call(definition)
        else
          Agent::Runner.new(
            session_id:       nil,
            model_override:   definition.resolved_model,
            max_turns:        definition.max_turns,
            ui:               child_ui,
            agent_definition: definition,
            event_bus:        Interaction::EventBus.new
          )
        end
      end

      # Builds the child UI for a BACKGROUND run. In the interactive CLI it's a
      # COLLAPSED-CARD SubagentView wired with this run's entry id (so its tool
      # activity feeds the registry/card instead of flooding $stdout), the parent
      # CLI (whose live region hosts the card), and the approval handler that
      # surfaces a needed approval on the card + parks the child on a per-entry
      # gate (Option 2). Off the CLI it's Null (headless/API stays silent and
      # auto-approves as before).
      def nested_ui_for(entry, parent_ui)
        if parent_ui.is_a?(UI::CLI)
          UI::SubagentView.new(
            agent_name: entry.subagent,
            entry_id:   entry.id,
            parent_ui:  parent_ui,
            approve:    approval_handler_for(entry)
          )
        else
          UI::Null.new
        end
      end

      # The approval handler the card-mode SubagentView calls when a background
      # child's tool needs approval. It flips the entry to :needs_approval (the
      # card now shows `● needs approval: <command>` + a parent note), registers a
      # per-entry Run::ApprovalGate, and BLOCKS the child thread on the gate's
      # bounded interruptible wait (15min → auto-deny; a /agents <id> --stop
      # cancel wakes it to a deny). The user's /agents <id> decision resolves the
      # gate; this returns the boolean to the child's tool. "Approve always" is
      # persisted by the parent decision path (the existing allowlist), so here we
      # only need the boolean.
      def approval_handler_for(entry)
        lambda do |question, scope: nil, command: nil, **_context|
          gate        = Run::ApprovalGate.new
          approval_id = entry.id
          gate.register(approval_id)
          cmd = (command && !command.to_s.empty?) ? command.to_s : scope.to_s
          BackgroundTasks.instance.begin_approval(
            entry.id, gate: gate, approval_id: approval_id,
            question: question, command: cmd
          )
          surface_completion(entry_parent_ui, "● #{entry.id} · #{entry.subagent} · needs approval: #{truncate(cmd, 80)} — /agents #{entry.id}")
          repaint_parent_cards(entry_parent_ui)
          begin
            decision = gate.await(approval_id)
            approved = decision_to_bool(decision)
          rescue Rubino::Interrupted
            approved = false # a stop/cancel while parked → deny and unwind
          ensure
            BackgroundTasks.instance.end_approval(entry.id)
            repaint_parent_cards(entry_parent_ui)
          end
          approved
        end
      end

      # The parent CLI captured for repaints inside the approval handler. The
      # handler runs on the CHILD thread, where Rubino.ui is the child's
      # SubagentView (bound by with_ui); the real parent CLI is the process-global
      # adapter, which is what hosts the live region.
      def entry_parent_ui
        Rubino.instance_variable_get(:@ui)
      end

      # Maps a gate decision to the boolean the child tool expects. EXPIRED (the
      # 15-min bound elapsed with no answer) is a safe DENY, mirroring UI::API.
      def decision_to_bool(decision)
        return false if decision.equal?(Run::ApprovalGate::EXPIRED)

        !!decision
      end

      def truncate(text, max)
        s = text.to_s
        s.length > max ? "#{s[0, max]}…" : s
      end

      # Runs a FRESH nested agent turn for the given subagent definition and
      # returns its final assistant message as the tool result string.
      #
      # The nested run uses a brand-new session (session_id: nil ⇒ created
      # fresh) so the parent transcript never leaks. It runs synchronously —
      # the parent waits — and is capped by the subagent's own `max_turns`.
      # The nested loop's own tool events fire on the child's executor only;
      # the parent recorder sees just this tool's start/complete boundary.
      def run_subagent(definition, prompt)
        runner = build_runner(definition)
        result = runner.run!(prompt)
        text   = result.to_s.strip
        text.empty? ? "(subagent '#{definition.name}' #{NOOP_RESULT_SUFFIX}" : text
      end

      # Builds the nested Runner. Injectable via the constructor for tests
      # (so a FakeLLMAdapter can drive the child loop); defaults to a real
      # Runner wired with the subagent's resolved model / max_turns and a
      # fresh ephemeral session. The child UI is chosen by #nested_ui: a
      # live nested view in the interactive CLI, silent (Null) everywhere else.
      def build_runner(definition)
        if @runner_factory
          @runner_factory.call(definition)
        else
          Agent::Runner.new(
            session_id:       nil,
            model_override:   definition.resolved_model,
            max_turns:        definition.max_turns,
            ui:               nested_ui(definition),
            agent_definition: definition
          )
        end
      end

      # The UI the child loop renders through.
      #
      # Interactive CLI → UI::SubagentView: the subagent's tool activity shows
      # INLINE, nested + colored under the parent's "● delegato → X" row (the
      # only "watch live" that fits our scroll-native + bottom-composer model).
      # It is DISPLAY-ONLY — it writes to $stdout and never touches the parent
      # loop's messages or recorder, so the result-only contract holds.
      #
      # API / headless / tests (UI::Null, UI::API, …) → UI::Null: the child
      # stays silent so the boundary-only contract for SSE consumers and the
      # non-interactive paths is unchanged (the web nested view is a separate
      # follow-up).
      def nested_ui(definition)
        if Rubino.ui.is_a?(UI::CLI)
          UI::SubagentView.new(agent_name: definition.name)
        else
          UI::Null.new
        end
      end

      # Optional injection point for tests — a callable taking the resolved
      # Definition and returning something that responds to #run!(prompt).
      def initialize(runner_factory: nil)
        @runner_factory = runner_factory
      end

      def registry
        Rubino.agent_registry
      end

      def available_subagent_names
        registry.subagents.map(&:name)
      end

      def available_subagents_description
        registry.subagents.map do |a|
          desc = a.description.to_s.strip
          desc.empty? ? a.name : "#{a.name} (#{desc})"
        end.join("; ")
      end
    end
  end
end
