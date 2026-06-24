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
      # the run did nothing / was denied. Shared by completion_marker so the
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

      # The "NEVER claim a task was started…" sentence is the #149 guardrail:
      # the model was observed confirming a spawn ("Started: sa_…") with a task
      # id RECYCLED from earlier context, without calling this tool at all. The
      # ids are unguessable (SecureRandom), so the only honest source of a NEW
      # id is this tool's own return value — the description says so explicitly.
      # Prompt-level by design: a render-time transcript scanner would be a far
      # bigger surface for a model-behavior bug the user can already audit via
      # the turn footer (0 tools) and /agents.
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
          "needs into `prompt`. NEVER claim a task was started unless THIS call just " \
          "returned its id in the current turn — `sa_…` ids from earlier in the " \
          "conversation belong to old tasks and must not be reported as new ones. " \
          "Available subagents: #{available_subagents_description}."
      end

      def input_schema
        {
          type: "object",
          properties: {
            subagent: { type: "string",
                        description: "Name of the subagent to delegate to (#{available_subagent_names.join(", ")})" },
            prompt: { type: "string",
                      description: "The full self-contained task for the subagent (the only context it receives)" },
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
                 "Valid subagents: #{available_subagent_names.join(", ")}."
        end

        # Force FOREGROUND in headless one-shot (#380): a `rubino prompt`/-q run
        # has no IdleCardHost to fold a background child's result back in, and the
        # process exits the instant the parent's answer is ready — so a background
        # subagent's result would be silently dropped (its notice sink is nil and
        # its thread is killed on exit). Running synchronously returns the child's
        # final text as THIS tool's result, so it lands in the parent transcript
        # and is factored into the one-shot answer, making `task` reliable headless.
        if background && !Rubino.headless?
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
        # SSE/recorder sees the lifecycle), parent_ui is the TOP-LEVEL CLI that
        # hosts the collapsed-card live region (so the card + the approval note
        # surface there, like background-shell does).
        sink      = Rubino.background_sink
        event_bus = Rubino.active_event_bus
        # The card host is the ROOT CLI, not the thread-local Rubino.ui. When a
        # SUBAGENT spawns a (grand)child (S1 nesting), the spawner runs under
        # with_ui(its own per-sub UI), so Rubino.ui here is that wrapped sub UI —
        # NOT the top-level UI::CLI. nested_ui_for keys card-mode on the parent
        # being a UI::CLI, so the thread-local would make a nested child fall
        # through to a Null view with NO approval handler: its approval-gated tools
        # would then fail closed
        # with the headless :noninteractive block instead of escalating to the
        # parent (#86). The single live region is owned by the one top-level CLI
        # (the process-global @ui, the same host entry_parent_ui resolves), so
        # EVERY card — depth-1 or nested — renders and escalates through it.
        parent_ui = root_cli
        # Stash the spawn-captured sink on the entry so a tool running on the
        # CHILD's thread (ask_parent) can notify the parent MODEL without
        # reading the child's own thread-local sink — which is the child's own
        # steer_queue, not the parent's queue (#195).
        entry.parent_sink = sink
        # Build the child UI on the PARENT thread so the collapsed-card view is
        # wired with this run's entry id + the parent CLI (whose live region hosts
        # the card) + the approval handler. In card mode the child's per-tool
        # activity feeds the registry instead of flooding $stdout (#124).
        child_ui  = nested_ui_for(entry, parent_ui,
                                  approve: approval_handler_for(entry),
                                  budget: budget_handler_for(entry))
        runner    = build_subagent_runner(
          definition, ui: child_ui, event_bus: Interaction::EventBus.new
        )

        thread = Thread.new do
          run_child_thread(entry, runner, prompt, sink, event_bus, parent_ui, child_ui)
        end
        # #run_child_thread already rescues Exception, but never let a dying child
        # auto-dump a backtrace into the parent's terminal — e.g. if shutdown!'s
        # Thread#kill or a stray Interrupt unwinds it through a net/http read.
        thread.report_on_exception = false
        registry_bg.attach(entry, thread: thread, runner: runner)

        event_bus&.emit(Interaction::Events::SUBAGENT_SPAWNED,
                        task_id: entry.id, subagent: definition.name,
                        prompt: Rubino::Util::Output.elide(prompt, 200))
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
        ui_for_child = child_ui || nested_ui_for(entry, parent_ui,
                                                 approve: approval_handler_for(entry),
                                                 budget: budget_handler_for(entry))
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
        text = result_or_noop(result, entry.subagent)

        record_completion(entry, text, sink, parent_ui)
        # The OLD AttachedAgentWatcher closed its live tail with a "✓ finished —
        # press ← to return" affordance shown only while the user was attached to
        # THIS sub. Re-home it onto the sub's OWN UI: it commits with this sub's
        # origin, so the bottom composer's focus-gate paints it only when the user
        # is attached to this sub (and drops it otherwise) — no watcher needed.
        finished_affordance(ui_for_child, entry)
        repaint_parent_cards(parent_ui)
        event_bus&.emit(Interaction::Events::SUBAGENT_COMPLETED,
                        task_id: entry.id, subagent: entry.subagent,
                        status: "completed", output: Rubino::Util::Output.elide(text, 400))
      rescue Exception => e # rubocop:disable Lint/RescueException
        BackgroundTasks.instance.complete(entry, status: :failed, error: e.message)
        # A failure landing on a stop-requested entry was recorded as :stopped
        # (BackgroundTasks#complete): a deliberate /agents --stop / task_stop
        # must not surface as a ✗ "failed" notice (#108/#13).
        if entry.status == :stopped
          notify(sink, stopped_notice(entry))
          surface_completion(parent_ui, "⊘ #{entry.id} · #{entry.subagent} · stopped",
                             id: entry.id, status: "stopped")
        else
          notify(sink, failure_notice(entry, e.message))
          surface_completion(parent_ui, "✗ #{entry.id} · #{entry.subagent} · failed",
                             id: entry.id, status: "failed")
        end
        repaint_parent_cards(parent_ui)
        event_bus&.emit(Interaction::Events::SUBAGENT_FAILED,
                        task_id: entry.id, subagent: entry.subagent,
                        status: entry.status == :stopped ? "stopped" : "failed",
                        error: e.message)
      end

      # Records the terminal :completed state and notifies the parent.
      # Deliver-or-report for /agents steer (#140): a parked note the child
      # never got another turn to fold in would otherwise vanish silently —
      # the user believes the child was steered when it wasn't. Say so, on the
      # parent UI and in the completion notice.
      #
      # H5 — the final drain now happens INSIDE #complete, under the SAME
      # registry mutex that flips the status to terminal (and that #steer checks
      # before pushing). The previous shape drained the queue HERE (InputQueue
      # lock) and THEN called #complete (registry lock): a steer/answer arriving
      # in that gap landed on an already-drained queue — dropped, missing from
      # `undelivered`, yet reported delivered. Taking the drained notes from
      # #complete's return closes that gap: a note is either drained here (and
      # reported undelivered) or rejected by #steer (and reported not-delivered
      # to its caller) — never silently lost.
      def record_completion(entry, text, sink, parent_ui)
        drained = BackgroundTasks.instance.complete(entry, status: :completed, result: text)
        # Drop the gate-delivered answer COPIES (#457 regression): a /reply
        # answer is delivered to the child via its ask gate AND mirrored onto the
        # steer queue; when the child resumes via the gate and finishes without
        # another turn, that mirror is drained here. It was NOT undelivered — the
        # gate delivered it — so reporting it would surface a false "steer note
        # not delivered" alarm on the happy path. GENUINE steer notes (no
        # ANSWER_NOTE_PREFIX) still report undelivered, preserving #457's invariant.
        # A drained gate-answer COPY (#457) is not undelivered — the gate
        # delivered it; drop it. A drained DENY-note (#Y1B) is ADVISORY — the
        # approval was already denied, so a "couldn't deliver it" alarm is
        # misleading: the denial applied and the explanation is simply moot. Only
        # GENUINE `/agents <id> steer` notes (neither prefix) are a real
        # deliver-or-report case that warrants the scary warning.
        denied = drained.select { |n| n.to_s.start_with?(BackgroundTasks::DENY_NOTE_PREFIX) }
        undelivered = drained.reject do |n|
          s = n.to_s
          s.start_with?(BackgroundTasks::ANSWER_NOTE_PREFIX, BackgroundTasks::DENY_NOTE_PREFIX)
        end
        notify(sink, completion_notice(entry, text, undelivered: undelivered))
        unless undelivered.empty?
          surface_completion(parent_ui,
                             "⚠ #{entry.id} · steer note not delivered (task completed first): " \
                             "#{Rubino::Util::Output.elide(undelivered.join(" | "), 80)}")
        end
        # Calm, non-alarming note for a moot deny explanation (no ⚠): the denial
        # was applied; the agent just finished before reading why.
        unless denied.empty?
          surface_completion(parent_ui,
                             "#{entry.id} · denial applied; the agent finished before reading the note")
        end
        status = self.class.noop_result?(text) ? "no-op" : "done"
        surface_completion(parent_ui, completion_marker(entry, status),
                           id: entry.id, status: status)
      end

      # The MINIMAL main-timeline marker for a finished background subagent
      # (agent-multiplexer Slice 1): `✓ <id> · <name> · done` / `⊘ <id> · <name>
      # · no-op`. The id LEADS: a background child finishes far below its
      # `● delegated → <name>` row in the append-only scroll (the parent kept
      # streaming in between), so the done marker must self-identify by id rather
      # than pretend to be `└`-nested under whatever row happens to precede it —
      # and two same-named children (`explore`) stay distinguishable. NO result
      # summary / tool count / report reaches the main scrollback — all per-tool
      # detail lives in the registry (card / /agents drill-in); the full result
      # reaches the MODEL via the InputQueue notice + task_result. A no-op /
      # fully-denied run (#16) reads "no-op", never a misleading green ✓.
      def completion_marker(entry, status)
        icon = status == "no-op" ? "⊘" : "✓"
        "#{icon} #{entry.id} · #{entry.subagent} · #{status}"
      end

      # Rings the parent's attention notifier (bell/command hook) for a child
      # parked on an approval — the same best-effort contract as the card
      # repaint. No-op off the CLI (Null/API expose no notifier).
      def ring_parent_attention(entry, preview)
        parent_ui = entry_parent_ui
        return unless parent_ui.respond_to?(:notifier)

        parent_ui.notifier.needs_approval("subagent #{entry.id} needs approval: #{preview}")
      rescue StandardError
        nil
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
      # A terminal-state notice (id + status given) goes through the CLI's
      # #subagent_finished so a completion landing at turn end folds into the
      # turn footer instead of stacking a second `┄ ┄` rail (P4).
      def surface_completion(parent_ui, line, id: nil, status: nil, report: nil)
        return unless parent_ui.is_a?(UI::CLI)

        if id && parent_ui.respond_to?(:subagent_finished)
          parent_ui.subagent_finished(line, id: id, status: status || "done", report: report)
        else
          parent_ui.note(line)
        end
      rescue StandardError
        # A UI hiccup must never wedge the worker's terminal-state bookkeeping.
      end

      # Commits the terminal affordance on the SUB's own UI when it finishes —
      # the "✓ <id> finished — press ← to return" line the old AttachedAgentWatcher
      # printed at the end of its live tail. Routed through the sub's UI (origin =
      # the sub) so the composer's focus-gate paints it only while attached to this
      # sub; off a real terminal (Null/foreground) the note is a quiet no-op.
      # Best-effort: a cosmetic note must never wedge the worker's bookkeeping.
      def finished_affordance(ui, entry)
        ui.info("✓ #{entry.id} finished · #{entry.status} — press ← or /back to return to main")
      rescue StandardError
        nil
      end

      # Parks the notice on the parent's InputQueue if one is wired — as a
      # NOTICE, not a typed line: the parent loop folds it in at an iteration
      # boundary of a live turn, or at the start of the NEXT real turn, never
      # as a standalone synthetic user turn at the idle prompt (#13). When no
      # sink exists (API/server, or the parent turn already ended) the result
      # still lives in the registry and is reachable via `task_result`.
      def notify(sink, text)
        sink&.push_notice(text)
      end

      def completion_notice(entry, text, undelivered: [])
        notice = "[background-task] Task #{entry.id} (subagent '#{entry.subagent}') completed.\n" \
                 "Result:\n#{Rubino::Util::Output.elide(text, 4000)}\n" \
                 "(full result via task_result(\"#{entry.id}\"))"
        return notice if undelivered.empty?

        notice + "\nNote: a steer note was NOT delivered (the task completed first): " \
                 "#{Rubino::Util::Output.elide(undelivered.join(" | "), 200)}"
      end

      def failure_notice(entry, message)
        "[background-task] Task #{entry.id} (subagent '#{entry.subagent}') failed: #{message}"
      end

      # The stopped notice must carry the ground truth about PARTIAL progress:
      # "no action needed" with zero detail led the parent model to assert that
      # nothing was produced while completed side effects (an approved write,
      # …) were already on disk (#150). Include the tool count + the activity
      # tail from the registry entry so neither the model nor the human is misled.
      def stopped_notice(entry)
        base  = "[background-task] Task #{entry.id} (subagent '#{entry.subagent}') was stopped " \
                "at the user's request"
        count = entry.tool_count.to_i
        return "#{base} before it ran any tools — no action needed." if count.zero?

        recent = Array(entry.activity_log).last(3).join("; ")
        detail = recent.empty? ? "" : " (recent: #{recent})"
        "#{base} after #{count} tool#{"s" if count != 1} had already run#{detail} — " \
          "completed tools' side effects may exist."
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
      # instead of one undifferentiated "at capacity". The message must NOT
      # recommend `background: false`: the sync path enforces the same ceilings
      # (#196), so it is not an escape hatch.
      def capacity_message(registry_bg)
        case registry_bg.last_refusal_reason
        when :depth
          "Max nesting depth reached: subagents can only nest #{BackgroundTasks::MAX_DEPTH} " \
          "levels deep. This subagent is too deep to delegate further — do the work " \
          "directly, or report back so a shallower agent can split it up."
        when :per_owner
          "At capacity: this agent already has #{BackgroundTasks::MAX_CHILDREN_PER_NODE} " \
          "subagents running. Wait for one to finish (you'll get a " \
          "`[background-task]` message), check it with task_result, or do the work " \
          "directly."
        else # :global (or any future ceiling)
          "At capacity: the maximum number of subagents " \
          "(#{BackgroundTasks::MAX_CONCURRENT_TOTAL}) are already running across all " \
          "agents. Wait for one to finish (you'll get a `[background-task]` message), " \
          "check it with task_result, or do the work directly."
        end
      end

      # Background children get their OWN fresh EventBus so their inner tool
      # events stay off the parent recorder (the result-only isolation contract).
      # Built directly here (not via @runner_factory, which tests use to inject a
      # stub for the SYNC path) so the bus wiring is always honored.
      # A subagent's final result text, or the neutral no-op placeholder when the
      # run produced nothing / was fully denied (#16). One spelling for both the
      # sync and background completion paths, recognized by .noop_result?.
      def result_or_noop(result, name)
        text = result.to_s.strip
        text.empty? ? "(subagent '#{name}' #{NOOP_RESULT_SUFFIX}" : text
      end

      # Builds the nested Runner for BOTH the sync and background paths.
      # Injectable via the constructor for tests (a FakeLLMAdapter can drive the
      # child loop). Both paths build the child UI via #nested_ui_for (the
      # per-sub UI::CLI on the interactive CLI, Null off it) so neither floods
      # $stdout with inline rows; they differ only in the event bus: the
      # background path injects a
      # fresh per-run EventBus so concurrent runs don't cross-contaminate, while
      # the sync path passes nil and inherits Rubino.event_bus (the same result
      # as omitting it). The fresh session is always tagged session_source
      # "subagent" so it's hidden from the user-facing /sessions picker (item 2).
      def build_subagent_runner(definition, ui:, event_bus: nil)
        if @runner_factory
          @runner_factory.call(definition)
        else
          Agent::Runner.new(
            session_id: nil,
            model_override: definition.resolved_model,
            max_turns: definition.max_turns,
            ui: ui,
            agent_definition: definition,
            event_bus: event_bus,
            session_source: "subagent"
          )
        end
      end

      # Builds the child UI (tmux-style unified render). In the interactive CLI
      # the subagent gets its OWN UI::CLI instance, tagged with this run's entry id
      # as its `agent_id` — so every frame it commits to the bottom composer
      # carries that origin and the composer's focus-gate paints it ONLY while the
      # user is attached to this sub (live tool rows + streaming prose, identical
      # to main), and drops it otherwise. The per-sub CLI is wrapped in a
      # UI::SubagentRecorder that keeps the registry counters (tool_count /
      # last_activity / activity_log / output_tail) current so the OFF-screen
      # surfaces — probe_tool, /agents drill-in, the ambient cards — still update
      # even when this sub isn't focused. Off the CLI it's Null (headless/API stays
      # silent and auto-approves as before).
      #
      # +approve+ is the handler the per-sub CLI's #confirm calls when a child's
      # tool needs human approval: the BACKGROUND path passes #approval_handler_for
      # (surface on the card + park the child thread on a per-entry gate). The SYNC
      # path passes NOTHING (nil) — a sync child runs on the PARENT TURN's own
      # thread, so parking it on a 15-min human gate would block the whole REPL
      # with no idle prompt to resolve it; nil keeps the historical fail-closed
      # auto-deny.
      #
      # +budget+ is the handler #select calls when a child hits its tool-iteration
      # ceiling and asks for more budget (#574). Same split as +approve+: the
      # BACKGROUND path passes #budget_handler_for (park + dropdown grant); the
      # SYNC path passes nil — a sync child on the parent thread can't park, so it
      # force-summarizes (nil #select), exactly as today.
      def nested_ui_for(entry, parent_ui, approve: nil, budget: nil)
        if parent_ui.is_a?(UI::CLI)
          cli = UI::CLI.new(
            agent_id: entry.id,
            approval_handler: approve,
            budget_handler: budget
          )
          UI::SubagentRecorder.new(cli, entry_id: entry.id)
        else
          UI::Null.new
        end
      end

      # The approval handler the per-sub CLI's #confirm calls when a background
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
          cmd = command && !command.to_s.empty? ? command.to_s : scope.to_s
          BackgroundTasks.instance.begin_approval(
            entry.id, gate: gate, approval_id: approval_id,
                      question: question, command: cmd
          )
          # The committed parent note shows a ONE-LINE elided preview. A
          # multi-line command (ruby code, often starting with a blank line)
          # truncated by raw character count committed its first code lines as
          # bare unframed rows under the card — and an empty first line left
          # "needs approval:" with no body at all (#141). Fall back to the
          # question when the command has no usable line.
          preview = approval_preview(cmd, question)
          surface_completion(entry_parent_ui,
                             "● #{entry.id} · #{entry.subagent} · needs approval: #{preview} — /agents #{entry.id}")
          repaint_parent_cards(entry_parent_ui)
          ring_parent_attention(entry, preview)
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

      # The budget-request handler the per-sub CLI calls (via #select)
      # when a BACKGROUND child hits its tool-iteration ceiling (#574). It REUSES
      # the approval gate: flips the entry to :needs_approval flagged as a BUDGET
      # request (so the card / menu / resolve prompt read "wants +budget — grant?"
      # rather than a tool approval), registers a per-entry Run::ApprovalGate, and
      # BLOCKS the child thread on the gate's bounded wait (15min → summarize; a
      # /agents <id> --stop cancel wakes it to summarize). The human grants/denies
      # from the dropdown (Enter on the parked agent) or `/agents <id>`. The
      # boolean decision is mapped to the Loop's #select contract: grant →
      # :continue (the Loop raises the cap +step and re-enters the turn);
      # deny / timeout / cancel → :summarize (force-summarize, today's behaviour).
      def budget_handler_for(entry)
        lambda do |question, *_args|
          gate        = Run::ApprovalGate.new
          approval_id = entry.id
          gate.register(approval_id)
          BackgroundTasks.instance.begin_approval(
            entry.id, gate: gate, approval_id: approval_id,
                      question: question.to_s, command: nil, budget: true
          )
          preview = Rubino::Util::Output.elide(
            Rubino::Util::Output.first_nonblank_line(question.to_s), 80
          )
          surface_completion(entry_parent_ui,
                             "⏏ #{entry.id} · #{entry.subagent} · wants +budget: #{preview} — /agents #{entry.id}")
          repaint_parent_cards(entry_parent_ui)
          ring_parent_attention(entry, "wants +budget: #{preview}")
          begin
            granted = decision_to_bool(gate.await(approval_id))
          rescue Rubino::Interrupted
            granted = false # a stop/cancel while parked → summarize and unwind
          ensure
            BackgroundTasks.instance.end_approval(entry.id)
            repaint_parent_cards(entry_parent_ui)
          end
          granted ? :continue : :summarize
        end
      end

      # The parent CLI captured for repaints inside the approval handler. The
      # handler runs on the CHILD thread, where Rubino.ui is the child's
      # per-sub UI (bound by with_ui); the real parent CLI is the process-global
      # adapter, which is what hosts the live region.
      def entry_parent_ui
        root_cli
      end

      # The TOP-LEVEL CLI that owns the collapsed-card live region. This is the
      # process-global UI adapter, NOT the thread-local Rubino.ui: a nested
      # subagent (S1) spawns from a thread bound by with_ui(its own per-sub UI),
      # so Rubino.ui there is that wrapped UI, not the real CLI. Every card —
      # at any nesting depth — is hosted by the one top-level CLI, so resolving
      # the host here keeps both the card rendering and the approval escalation
      # (nested_ui_for's `is_a?(UI::CLI)` gate) working past depth 1 (#86).
      def root_cli
        Rubino.instance_variable_get(:@ui)
      end

      # Maps a gate decision to the boolean the child tool expects. EXPIRED (the
      # 15-min bound elapsed with no answer) is a safe DENY, mirroring UI::API.
      def decision_to_bool(decision)
        return false if decision.equal?(Run::ApprovalGate::EXPIRED)

        !!decision
      end

      # One-line approval preview for the parent note (#141): the first
      # NON-BLANK line of the command (elided), falling back to the question.
      def approval_preview(cmd, question)
        line = Rubino::Util::Output.first_nonblank_line(cmd)
        line = Rubino::Util::Output.first_nonblank_line(question) if line.empty?
        Rubino::Util::Output.elide(line, 80)
      end

      # Runs a FRESH nested agent turn for the given subagent definition and
      # returns its final assistant message as the tool result string.
      #
      # The nested run uses a brand-new session (session_id: nil ⇒ created
      # fresh) so the parent transcript never leaks. It runs synchronously —
      # the parent waits — and is capped by the subagent's own `max_turns`.
      # The nested loop's own tool events fire on the child's executor only;
      # the parent recorder sees just this tool's start/complete boundary.
      #
      # GOVERNED LIKE THE BACKGROUND PATH (#196): a sync child goes through the
      # SAME single enforcement point — BackgroundTasks#reserve — so all three
      # nesting caps apply and it counts toward the live totals for the whole
      # inline run; and it runs under with_current_subagent_id(entry.id) so
      # anything IT spawns is stamped with the right owner/depth. Without this,
      # `background: false` was an uncapped escape hatch that also corrupted
      # ownership/depth stamping for its entire subtree.
      def run_subagent(definition, prompt)
        registry_bg = BackgroundTasks.instance
        entry = registry_bg.reserve(
          subagent: definition.name, prompt: prompt,
          owner_subagent_id: Rubino.current_subagent_id, depth: 0
        )
        return capacity_message(registry_bg) unless entry

        # Same CARD-mode child UI as the background path (#124): the sync child's
        # per-tool activity feeds the registry/card instead of flooding $stdout
        # with inline `⟂` rows. Wired with this run's reserved entry id + the
        # parent CLI. NO approval handler is passed: a sync child runs on the
        # PARENT TURN's own thread, so parking it on the 15-min human gate would
        # block the whole REPL with no idle prompt to resolve it — sync keeps the
        # historical fail-closed auto-deny until focus-gating lands. Off the CLI
        # this is Null (headless/API unchanged).
        runner = build_subagent_runner(definition, ui: nested_ui_for(entry, root_cli))
        registry_bg.attach(entry, thread: Thread.current, runner: runner)
        result = Rubino.with_current_subagent_id(entry.id) { runner.run!(prompt) }
        text   = result_or_noop(result, definition.name)
        registry_bg.complete(entry, status: :completed, result: text)
        text
      rescue StandardError => e
        # Release the reserved slot on ANY failure so a raising sync child can
        # never wedge a live-slot leak; #call's rescue phrases the message.
        registry_bg.complete(entry, status: :failed, error: e.message) if entry
        raise
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
