# frozen_string_literal: true

module Rubino
  module MCP
    # Wraps an MCP tool (from ruby_llm-mcp) into the Rubino::Tools::Base interface.
    # This allows MCP tools to be used seamlessly alongside built-in tools.
    class MCPToolWrapper < Tools::Base
      attr_reader :mcp_tool, :server_name

      def initialize(mcp_tool, server_name:)
        @mcp_tool = mcp_tool
        @server_name = server_name
      end

      def name
        # Prefix with server name to avoid collisions
        "#{@server_name}_#{@mcp_tool.name}"
      end

      def description
        @mcp_tool.description
      end

      def input_schema
        # ruby_llm-mcp tools expose their schema
        if @mcp_tool.respond_to?(:parameters)
          @mcp_tool.parameters
        else
          { type: "object", properties: {} }
        end
      end

      def risk_level
        # MCP tools are external, default to medium risk
        :medium
      end

      def call(arguments)
        result = @mcp_tool.execute(**symbolize_keys(arguments))
        result.to_s
      rescue StandardError => e
        "MCP tool error (#{@server_name}/#{@mcp_tool.name}): #{e.message}"
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
