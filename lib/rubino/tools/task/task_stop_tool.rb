# frozen_string_literal: true

module Rubino
  module Tools
    # Cancels a running background subagent started by `task`. The KillShell
    # analogue: flips the child Runner's CancelToken (the exact mechanism
    # Run::Executor's stop-watcher uses for top-level runs), which unwinds the
    # child loop cooperatively at its next cancel checkpoint.
    class TaskStopTool < Rubino::Tool
      risk :medium

      def config_key
        "task"
      end

      # The live statuses a stop applies to. A child parked on a human approval
      # still holds its thread + concurrency slot (Tools::BackgroundTasks#live_status?),
      # so it MUST be stoppable — refusing left a blocked child as a zombie
      # holding its slot until the approval gate timeout (#197). :stopping is
      # excluded: a second stop is honestly "already stopping — nothing to stop".
      STOPPABLE = %i[running needs_approval].freeze

      describe "Stop a running background subagent started by `task` — including one " \
              "parked on an approval. Cancels the " \
              "subagent's nested run; its task_result will then report failed/cancelled."

      string :task_id, "The task id (sa_…) returned by `task`."

      def execute(task_id:)
        task_id = task_id.to_s.strip

        registry = Tools::BackgroundTasks.instance
        entry    = registry.find(task_id)
        return "Error: no background subagent with task_id=#{task_id}" unless entry

        return "[#{task_id}] already #{entry.status} — nothing to stop." unless STOPPABLE.include?(entry.status)

        # The shared per-entry stop body (the SAME one the human /agents <id>
        # --stop path and the parent-teardown #cancel_all use): mark the stop so
        # the list/cards show ◌ stopping and the unwind records as :stopped, not
        # failed (#108/#13); cancel the child's OWN approval gate so a parked wait
        # wakes (Interrupted → deny/cancel) and unwinds NOW instead of holding its
        # thread + slot until the bound elapses (#197); and flip the runner's
        # CancelToken so a child between checkpoints observes it at its next one.
        registry.stop_entry(entry)
        "[#{task_id}] stop requested (subagent '#{entry.subagent}'). " \
          "It will unwind at its next checkpoint; check task_result(\"#{task_id}\")."
      end
    end
  end
end
