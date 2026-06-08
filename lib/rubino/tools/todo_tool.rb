# frozen_string_literal: true

module Rubino
  module Tools
    # Tool for managing a task/todo list during a session.
    # Allows the agent to track progress on complex multi-step tasks.
    class TodoTool < Base
      def name
        "todowrite"
      end

      def description
        "Create and manage a structured task list for the current session. " \
        "Use this to track progress on complex multi-step tasks. " \
        "Tasks have content, status (pending/in_progress/completed/cancelled), and priority."
      end

      def input_schema
        {
          type: "object",
          properties: {
            todos: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  content: { type: "string", description: "Brief description of the task" },
                  status: {
                    type: "string",
                    enum: %w[pending in_progress completed cancelled],
                    description: "Current task status"
                  },
                  priority: {
                    type: "string",
                    enum: %w[high medium low],
                    description: "Task priority level"
                  }
                },
                required: %w[content status priority]
              },
              description: "The complete updated todo list"
            }
          },
          required: %w[todos]
        }
      end

      def risk_level
        :low
      end

      def call(arguments)
        todos = arguments["todos"] || arguments[:todos]
        return "Error: No todos provided" unless todos.is_a?(Array)

        format_todo_summary(todos)
      end

      private

      def format_todo_summary(todos)
        completed = todos.count { |t| t["status"] == "completed" || t[:status] == "completed" }
        in_progress = todos.count { |t| t["status"] == "in_progress" || t[:status] == "in_progress" }
        pending = todos.count { |t| t["status"] == "pending" || t[:status] == "pending" }
        cancelled = todos.count { |t| t["status"] == "cancelled" || t[:status] == "cancelled" }

        lines = ["Todo list updated (#{todos.size} items):"]
        lines << "  Completed: #{completed}" if completed > 0
        lines << "  In Progress: #{in_progress}" if in_progress > 0
        lines << "  Pending: #{pending}" if pending > 0
        lines << "  Cancelled: #{cancelled}" if cancelled > 0
        lines << ""

        todos.each do |todo|
          content = todo["content"] || todo[:content]
          status = todo["status"] || todo[:status]
          priority = todo["priority"] || todo[:priority]

          icon = case status
                 when "completed" then "[x]"
                 when "in_progress" then "[>]"
                 when "cancelled" then "[-]"
                 else "[ ]"
                 end

          lines << "  #{icon} #{content} (#{priority})"
        end

        lines.join("\n")
      end
    end
  end
end
