# frozen_string_literal: true

module Rubino
  module Tools
    # Cancels a running background subagent started by `task`. The KillShell
    # analogue: flips the child Runner's CancelToken (the exact mechanism
    # Run::Executor's stop-watcher uses for top-level runs), which unwinds the
    # child loop cooperatively at its next cancel checkpoint.
    class TaskStopTool < Base
      def name
        "task_stop"
      end

      def config_key
        "task"
      end

      def description
        "Stop a running background subagent started by `task`. Cancels the " \
          "subagent's nested run; its task_result will then report failed/cancelled."
      end

      def input_schema
        {
          type: "object",
          properties: {
            task_id: {
              type: "string",
              description: "The task id (sa_…) returned by `task`."
            }
          },
          required: %w[task_id]
        }
      end

      def risk_level
        :medium
      end

      def call(arguments)
        task_id = (arguments["task_id"] || arguments[:task_id]).to_s.strip
        return "Error: task_id is required" if task_id.empty?

        registry = BackgroundTasks.instance
        entry    = registry.find(task_id)
        return "Error: no background subagent with task_id=#{task_id}" unless entry

        return "[#{task_id}] already #{entry.status} — nothing to stop." unless entry.status == :running

        entry.runner&.cancel!
        # Stop-cascade (S5a): wake any descendant parked on a blocking ask_parent
        # so the whole subtree unwinds at once (no orphaned blocked grandchild).
        registry.cancel_descendant_ask_gates(task_id)
        "[#{task_id}] stop requested (subagent '#{entry.subagent}'). " \
          "It will unwind at its next checkpoint; check task_result(\"#{task_id}\")."
      end
    end
  end
end
