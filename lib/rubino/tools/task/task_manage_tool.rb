# frozen_string_literal: true

require_relative "../subagent_probe"

module Rubino
  module Tools
    # task_manage — the SINGLE management surface for a background subagent
    # started by `task` (mirrors Hermes' one delegate + one manage tool, and the
    # `shell_manage` collapse on the shell side). It folds the four former tools
    # — `task_result`, `task_stop`, `steer`, `probe` — into one `action`-selected
    # tool so the model has ONE verb to poll/cancel/steer/inspect a child instead
    # of four look-alike tools. Each action dispatches to the SAME registry logic
    # the old tools used verbatim:
    #
    #   result — status/output of a background subagent (the BashOutput analogue);
    #            with NO id it LISTS every tracked subagent (the /tasks analogue).
    #            Read-only; unscoped (any id / list-all), as `task_result` was.
    #   stop   — cancel a running subagent (the KillShell analogue): flips its
    #            CancelToken + wakes a parked approval gate so it unwinds now.
    #   steer  — park a PERSISTENT note folded into the child's NEXT turn (S2).
    #   probe  — NON-disturbing instant status snapshot of a child (S3, free path):
    #            status / tool_count / last activity / recent lines, NO model call.
    #
    # Ownership (S1): the mutating/inspecting actions (stop/steer/probe) are
    # AUTHORIZED by ownership at call time — the caller is the thread-local
    # Rubino.current_subagent_id (nil ⇒ human/top-level) and the target must be the
    # caller's OWN direct child (BackgroundTasks#owned_by?), so a node with no
    # children just gets a "not your child" error. `result` stays unscoped (its
    # list-all is the /tasks view), exactly as `task_result` was.
    class TaskManageTool < Rubino::Tool
      redaction :none

      # The live statuses a stop applies to (from the old TaskStopTool). A child
      # parked on a human approval still holds its thread + concurrency slot, so it
      # MUST be stoppable (#197); :stopping is excluded — a second stop is honestly
      # "already stopping — nothing to stop".
      STOPPABLE = %i[running needs_approval].freeze

      # How many activity_log lines the cheap probe snapshot renders (matches the
      # /agents drill-in's `recent:` ring).
      RECENT_MAX = 6

      # A probe is a snapshot at this instant: a child probed right after spawn has
      # run nothing yet and honestly reports an empty context, which reads as
      # broken without this hint (#112).
      JUST_STARTED_HINT = "(snapshot at this instant — the child just started and its " \
                          "context is still empty; probe again in a moment)"

      VALID_ACTIONS = %w[result stop steer probe].freeze

      def initialize(probe: nil)
        # Test seam: inject a Tools::SubagentProbe (or any object responding to
        # #peek) so the live probe path can be driven without a real model.
        @probe = probe
      end

      # Shares the `task` config gate — disabling delegation disables the whole
      # management surface too.
      def config_key
        "task"
      end

      describe "Manage a background subagent started by `task`: get its result, stop " \
                  "it, steer it with a note, or probe its status. Pick the operation with " \
                  "`action` and address the subagent by its `sa_…` `id`. " \
                  "action:result returns the subagent's status/output (omit `id` to LIST " \
                  "every background subagent); action:stop cancels a running subagent; " \
                  "action:steer parks a short `note` that folds into the child's NEXT turn " \
                  "and persists; action:probe checks on it WITHOUT disturbing it — by " \
                  "default (`live:false`) a FREE instant snapshot (status, tool count, last " \
                  "activity, recent lines — no model call), or set `live:true` to ask the " \
                  "child a specific `question` answered from its current context by a billed " \
                  "one-shot peek (budgeted per child; prefer the free snapshot). You can " \
                  "only stop/steer/probe subagents YOU started (your direct children)."

      string :id, "The subagent id (sa_…) returned by `task`. Required for stop/steer/probe; " \
                  "omit with action:result to list every background subagent.", default: nil
      string :action, "What to do: `result` (status/output, or list all when no id), " \
                      "`stop` (cancel it), `steer` (park a note for its next turn), " \
                      "`probe` (non-disturbing status check)."
      string :note, "The steering note — action:steer ONLY. Folded into the child's next " \
                    "turn; keep it short and self-contained.", default: nil
      string :question, "action:probe ONLY. What you want to know: for a free snapshot " \
                        "(live:false) this frames the check; for live:true it is the question " \
                        "the child answers from its context.", default: nil
      boolean :live, "action:probe ONLY. false (default) = FREE instant snapshot from the " \
                     "registry, no model call. true = billed one-shot model peek over the " \
                     "child's transcript (budgeted per child).", default: false

      def execute(action:, id: nil, note: nil, question: nil, live: false)
        action = action.to_s.strip.downcase
        id     = id.to_s.strip

        case action
        when "result" then act_result(id)
        when "stop"   then act_stop(id)
        when "steer"  then act_steer(id, note)
        when "probe"  then act_probe(id, question, live)
        else
          "Error: unknown action '#{action}'. Valid actions: #{VALID_ACTIONS.join(", ")}."
        end
      end

      private

      # ── result (verbatim from TaskResultTool) ─────────────────────────────
      # Unscoped: reads any tracked subagent, or lists them all when no id.

      def act_result(id)
        registry = Tools::BackgroundTasks.instance
        return list_all(registry) if id.empty?

        entry = registry.find(id)
        return "Error: no background subagent with id=#{id}" unless entry

        render(entry)
      end

      def render(entry)
        case entry.status
        when :running
          Result.success(
            name: name,
            call_id: nil,
            output: "[#{entry.id}] status=running (subagent '#{entry.subagent}', " \
                    "started #{elapsed(entry)}s ago) — still running. Do NOT poll again now; " \
                    "you will be auto-notified when it completes.",
            transcript_card: false
          )
        when :completed
          banner = TaskTool.truncation_banner(entry.stop_reason)
          label  = banner ? "completed (PARTIAL — cut off before finishing)" : "completed"
          body   = banner ? "#{banner}\n\n#{entry.result}" : entry.result.to_s
          "[#{entry.id}] status=#{label} (subagent '#{entry.subagent}')\n#{body}"
        when :failed
          "[#{entry.id}] status=failed (subagent '#{entry.subagent}'): #{entry.error}"
        else
          "[#{entry.id}] status=#{entry.status}"
        end
      end

      def list_all(registry)
        entries = registry.list
        return "No background subagents have been started." if entries.empty?

        lines = entries.map do |e|
          "[#{e.id}] #{e.status} · #{e.subagent} · started #{elapsed(e)}s ago"
        end
        "Background subagents:\n#{lines.join("\n")}"
      end

      def elapsed(entry)
        ((entry.finished_at || Time.now) - entry.started_at).round
      end

      # ── stop (verbatim from TaskStopTool + the ownership check) ────────────

      def act_stop(id)
        return "Error: action:stop requires a subagent id (sa_…)." if id.empty?

        registry = Tools::BackgroundTasks.instance
        entry    = registry.find(id)
        return "Error: no background subagent with id=#{id}" unless entry
        return not_your_child(id, "stop") unless owned_by?(id)

        return "[#{id}] already #{entry.status} — nothing to stop." unless STOPPABLE.include?(entry.status)

        # The shared per-entry stop body: mark the stop so the unwind records as
        # :stopped not failed (#108/#13); cancel the child's OWN approval gate so a
        # parked wait wakes and unwinds NOW instead of holding its thread + slot
        # (#197); and flip the runner's CancelToken so a child between checkpoints
        # observes it at its next one.
        registry.stop_entry(entry)
        "[#{id}] stop requested (subagent '#{entry.subagent}'). " \
          "It will unwind at its next checkpoint; check task_manage id=#{id} action=result."
      end

      # ── steer (verbatim from SteerTool + explicit note validation) ─────────

      def act_steer(id, note)
        note = note.to_s.strip
        return "Error: action:steer requires a subagent id (sa_…)." if id.empty?
        return "Error: action:steer requires a note." if note.empty?

        caller_id = Rubino.current_subagent_id
        registry  = Tools::BackgroundTasks.instance
        entry     = registry.find(id)

        # No such id at all → it is not a steerable running subagent.
        return "Cannot steer #{id} — no such running subagent." unless entry
        # Self-steer is meaningless and would loop a note into your own context.
        return "Error: cannot steer yourself." if id == caller_id
        # Ownership: only a DIRECT child of the caller may be steered.
        return not_your_child(id, "steer") unless registry.owned_by?(caller_id, id)
        # A finished child has no live loop to fold the note into.
        return "Cannot steer #{id} — it already finished (#{entry.status})." unless live?(entry.status)

        # Wraps the SAME wire the human CLI uses. A false here means the child's
        # queue vanished between checks (a just-finished child) — treat as gone.
        return "Cannot steer #{id} — no such running subagent." unless registry.steer(id, note)

        "steer ▸ #{id} ← #{Rubino::Util::Output.elide(note, 80)}  (parked · enters child context next turn)"
      end

      # ── probe (verbatim from ProbeTool — free snapshot + billed live peek) ──

      def act_probe(id, question, live)
        return "Error: action:probe requires a subagent id (sa_…)." if id.empty?

        registry = Tools::BackgroundTasks.instance
        entry    = registry.find(id)
        return "Cannot probe #{id} — no such subagent." unless entry
        return not_your_child(id, "probe") unless owned_by?(id)

        live ? probe_live(registry, entry, question) : probe_cheap(entry)
      end

      # FREE path: render the live-progress fields only. NO model call.
      def probe_cheap(entry)
        recent = Array(entry.activity_log).last(RECENT_MAX)
        lines  = recent.empty? ? "(none yet)" : recent.join("\n")
        out = "probe #{entry.id} · #{entry.subagent} · #{entry.status} · " \
              "#{entry.tool_count.to_i} tools · last: #{entry.last_activity || "—"}\n" \
              "recent:\n#{lines}"
        out += "\n#{JUST_STARTED_HINT}" if just_started?(entry)
        out
      end

      # BILLED path: enforce the per-child budget, then run the one-shot peek.
      # peek is best-effort (never raises) — a failure is reported inline.
      def probe_live(registry, entry, question)
        max = max_live_probes
        if entry.probe_count.to_i >= max
          return "Error: live-probe budget exhausted for #{entry.id} (max #{max} per child). " \
                 "Use live:false for a free snapshot."
        end

        registry.record_live_probe(entry.id)
        answer = probe_engine.peek(entry: entry, question: question)
        out    = "probe #{entry.id} (live) ⟵ #{answer}"
        out += "\n#{JUST_STARTED_HINT}" if just_started?(entry)
        out
      end

      def probe_engine
        @probe ||= Tools::SubagentProbe.new
      end

      def max_live_probes
        cfg = Rubino.configuration if Rubino.respond_to?(:configuration)
        Integer(cfg&.tasks_max_live_probes_per_child)
      rescue StandardError, TypeError, ArgumentError
        5
      end

      def just_started?(entry)
        entry.tool_count.to_i.zero?
      end

      # ── shared helpers ─────────────────────────────────────────────────────

      # Ownership predicate against the CALLER (thread-local current-subagent id,
      # nil ⇒ human/top-level). Wraps the same BackgroundTasks#owned_by? steer/probe
      # authorize on, so a target that is not the caller's direct child is refused.
      def owned_by?(id)
        Tools::BackgroundTasks.instance.owned_by?(Rubino.current_subagent_id, id)
      end

      def not_your_child(id, verb)
        "Error: #{id} is not one of your subagents — you can only #{verb} children you started."
      end

      # A child still holds a loop (its thread is alive) while running or awaiting
      # approval, so a steer note can still reach it.
      def live?(status)
        %i[running needs_approval].include?(status)
      end
    end
  end
end
