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
      # Shares the `task` config gate — disabling delegation disables its
      # companion poll/stop tools too.
      def config_key
        "task"
      end

      description "Fetch the status and result of a background subagent started by `task`. " \
                  "Returns `running` (still working), `completed` (with the full final " \
                  "result), or `failed` (with the error). Call without a task_id to list " \
                  "all tracked background subagents."

      param :task_id, desc: "The task id (sa_…) returned by `task`. Omit to list all background subagents.",
                      required: false

      def execute(task_id: nil)
        task_id = task_id.to_s.strip
        registry = Tools::BackgroundTasks.instance

        return list_all(registry) if task_id.empty?

        entry = registry.find(task_id)
        return "Error: no background subagent with task_id=#{task_id}" unless entry

        render(entry)
      end

      private

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
    end
  end
end
