# frozen_string_literal: true

module Rubino
  module Tools
    # Tool for git operations: status, diff, log, branch info.
    class GitTool < Base
      def name
        "git"
      end

      def description
        "Execute git commands to inspect repository state. " \
          "Supports status, diff, log, branch, and show operations."
      end

      def input_schema
        {
          type: "object",
          properties: {
            command: {
              type: "string",
              enum: %w[status diff log branch show],
              description: "The git command to execute"
            },
            args: {
              type: "string",
              description: "Additional arguments for the command"
            }
          },
          required: %w[command]
        }
      end

      def risk_level
        :low # Read-only git operations
      end

      def call(arguments)
        command = arguments["command"] || arguments[:command]
        args = arguments["args"] || arguments[:args] || ""

        case command
        when "status"
          execute_git("status", args)
        when "diff"
          execute_git("diff", args)
        when "log"
          execute_git("log --oneline -20", args)
        when "branch"
          execute_git("branch", args)
        when "show"
          execute_git("show", args)
        else
          "Unknown git command: #{command}"
        end
      end

      private

      def execute_git(cmd, args)
        # Split cmd into tokens and append sanitised args to avoid shell injection.
        # IO.popen with an argv array never passes the arguments through a shell.
        argv = ["git"] + cmd.split + args.split
        result = IO.popen(argv, err: %i[child out], &:read)
        result.empty? ? "(no output)" : result
      rescue StandardError => e
        "Git error: #{e.message}"
      end
    end
  end
end
