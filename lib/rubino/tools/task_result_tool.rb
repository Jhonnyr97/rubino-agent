# frozen_string_literal: true

module Rubino
  module Tools
    # Reads the status and result of a background subagent started by `task`
    # (the default background path). The BashOutput / TaskOutput analogue: lets
    # the model poll a background subagent deterministically even if it hasn't
    # yet received the auto-injected `[background-task] … completed` notice.
    #
    # Returns `running` (still working), `completed` (with the full final
    # result — not the truncated notice), or `failed` (with the error). With no
    # `task_id` it lists every tracked background subagent (the /tasks analogue).
    class TaskResultTool < Base
      def name
        "task_result"
      end

      # Shares the `task` config gate — disabling delegation disables its
      # companion poll/stop tools too.
      def config_key
        "task"
      end

      def description
        "Fetch the status and result of a background subagent started by `task`. " \
          "Returns `running` (still working), `completed` (with the full final " \
          "result), or `failed` (with the error). Call without a task_id to list " \
          "all tracked background subagents."
      end

      def input_schema
        {
          type: "object",
          properties: {
            task_id: {
              type: "string",
              description: "The task id (sa_…) returned by `task`. Omit to list all background subagents."
            }
          }
        }
      end

      def risk_level
        :low
      end

      def call(arguments)
        task_id = (arguments["task_id"] || arguments[:task_id]).to_s.strip
        registry = BackgroundTasks.instance

        return list_all(registry) if task_id.empty?

        entry = registry.find(task_id)
        return "Error: no background subagent with task_id=#{task_id}" unless entry

        render(entry)
      end

      private

      def render(entry)
        case entry.status
        when :running
          "[#{entry.id}] status=running (subagent '#{entry.subagent}', " \
          "started #{elapsed(entry)}s ago) — not finished yet; you'll be notified on completion."
        when :completed
          "[#{entry.id}] status=completed (subagent '#{entry.subagent}')\n#{entry.result}"
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
    end
  end
end
