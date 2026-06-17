# frozen_string_literal: true

module Rubino
  module MCP
    # Wraps an MCP tool (from ruby_llm-mcp) into the Rubino::Tools::Base interface.
    # This allows MCP tools to be used seamlessly alongside built-in tools.
    class MCPToolWrapper < Tools::Base
      attr_reader :mcp_tool, :server_name

      # Cap on the (prefixed) tool name length. A misbehaving MCP server can
      # advertise an absurdly long tool name (e.g. 20k chars), which would be
      # registered uncapped, blow up the `tools` table, and 400 at the provider.
      MAX_NAME_LENGTH = 64

      def initialize(mcp_tool, server_name:)
        @mcp_tool = mcp_tool
        @server_name = server_name
      end

      def name
        # Prefix with server name to avoid collisions. Cap the length so a
        # hostile/buggy server can't register a giant name that breaks the
        # `tools` table or 400s the provider (S1-MCP-2).
        "#{@server_name}_#{@mcp_tool.name}"[0, MAX_NAME_LENGTH]
      end

      def description
        @mcp_tool.description
      end

      def input_schema
        # The server-advertised JSON schema lives in RubyLLM::MCP::Tool#params_schema.
        # The inherited RubyLLM::Tool#parameters DSL accessor is ALWAYS empty for
        # MCP tools — forwarding it sent every tool to the model with `parameters:
        # {}`, so the model had to guess argument names and every call failed
        # server-side validation with -32602 (#170).
        schema = @mcp_tool.params_schema if @mcp_tool.respond_to?(:params_schema)
        # Coerce anything that isn't a Hash (nil, or a truthy non-Hash like a
        # string) to a valid empty object schema. A server advertising a
        # non-Hash `inputSchema` would otherwise poison the whole wire tool
        # list and 400 every subsequent model call (S1-MCP-1).
        schema.is_a?(Hash) ? schema : { type: "object", properties: {} }
      end

      def risk_level
        # MCP tools are external, default to medium risk
        :medium
      end

      def call(arguments)
        result = @mcp_tool.execute(**symbolize_keys(arguments))
        # ruby_llm-mcp reports tool failures by RETURNING `{ error: "…" }`
        # instead of raising. Map both failure paths onto the registry's
        # "Error: …" convention (Tools::Result#errorish?) so an errored MCP
        # call renders ✗ like any built-in tool, not "✓ done" (#172).
        error = result[:error] || result["error"] if result.is_a?(Hash)
        return "Error: MCP tool #{@server_name}/#{@mcp_tool.name}: #{error}" if error

        result.to_s
      rescue StandardError => e
        "Error: MCP tool #{@server_name}/#{@mcp_tool.name}: #{e.message}"
      end

      # Override to provide the raw MCP tool definition for LLM
      def to_tool_definition
        {
          name: name,
          description: description,
          parameters: input_schema
        }
      end

      private

      def symbolize_keys(hash)
        hash.transform_keys(&:to_sym)
      end
    end
  end
end
