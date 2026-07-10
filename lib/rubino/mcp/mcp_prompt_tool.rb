# frozen_string_literal: true

module Rubino
  module MCP
    # Exposes ONE connected MCP server's PROMPTS as a per-server built-in
    # tool, reusing rubino's tool / approval / redaction machinery.
    #
    # Registered PER SERVER by the Manager right alongside that server's
    # MCPToolWrappers (static toolset invariant, #313).  The model uses this
    # tool to list or get prompt templates from THAT single server — no
    # aggregate global iteration, no per-prompt registration bloat.
    #
    # Per-agent `mcp_servers` scoping works by construction because this tool
    # responds to `#mcp_server` (same seam as MCPToolWrapper), so
    # `Definition#reject_unscoped_mcp_tools` drops it just like any other
    # out-of-scope MCP tool.
    class McpPromptTool < Tools::Base
      attr_reader :server_name

      def initialize(client, server_name:)
        super()
        @client = client
        @server_name = server_name
      end

      # Collision-safe name that includes the server.  A server whose own
      # tool list includes the exact word "prompts" would collide — the
      # manager guards against that with a one-line Registry check.
      def name
        "#{@server_name}_prompts"[0, MCPToolWrapper::MAX_NAME_LENGTH]
      end

      def description
        "List or get prompts exposed by the \"#{@server_name}\" MCP server. " \
          "Use action \"list\" to see available prompts (name, description, arguments), " \
          "and action \"get\" with a specific name and optional arguments to fetch " \
          "the rendered prompt messages."
      end

      params do
        string :action, required: true, enum: %w[list get],
                        description: "Action: \"list\" to list prompts, \"get\" to fetch one"
        string :name, required: false, description: "Prompt name (required for \"get\")"
        object :arguments, required: false,
                           description: "Prompt arguments as key/value pairs (for \"get\")" do
          additional_properties true
        end
      end

      # Security: external MCP server data — medium risk, no sandbox.
      class PromptSecurity < Tools::ToolSecurity
        def risk = :medium
        def risky? = true
        def sandbox = :none
      end

      security PromptSecurity
      redaction_profile :shell # external content, explicit

      # Carried for the per-agent MCP scoping filter (Definition#reject_unscoped_mcp_tools).
      def mcp_server
        @server_name
      end

      def execute(action:, name: nil, arguments: nil)
        case action
        when "list"
          list_prompts
        when "get"
          get_prompt(name, arguments)
        else
          "Error: unknown action \"#{action}\" — use \"list\" or \"get\"."
        end
      end

      private

      def list_prompts
        prompts = safe_prompts
        return "No prompts exposed by \"#{@server_name}\"." if prompts.empty?

        lines = prompts.map do |prompt|
          args_str = if prompt.arguments.any?
                       prompt.arguments.map { |a| "#{a.name}#{"?" unless a.required}" }.join(", ")
                     else
                       "no args"
                     end
          desc = prompt.description.to_s.empty? ? "-" : prompt.description.to_s
          "  #{prompt.name} — #{desc} (args: #{args_str})"
        end

        "[#{@server_name}]\n#{lines.join("\n")}"
      end

      def get_prompt(name, arguments)
        return "Error: name is required for \"get\" action." if name.to_s.strip.empty?

        prompt = safe_prompts.find { |p| p.name == name.to_s.strip }
        return "Error: no MCP prompt found with name \"#{name}\" on server \"#{@server_name}\"." unless prompt

        args = arguments || {}
        messages = prompt.fetch(args)

        messages.map { |msg| "#{msg.role}: #{msg.content}" }.join("\n")
      rescue StandardError => e
        "Error: MCP prompt \"#{name}\": #{e.message}"
      end

      def safe_prompts
        @client.prompts
      rescue StandardError
        []
      end
    end
  end
end
