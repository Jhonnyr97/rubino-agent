# frozen_string_literal: true

module Rubino
  module MCP
    # Exposes ONE connected MCP server's RESOURCES as a per-server built-in
    # tool, reusing rubino's tool / approval / redaction machinery.
    #
    # Registered PER SERVER by the Manager right alongside that server's
    # MCPToolWrappers (static toolset invariant, #313).  The model uses this
    # tool to list or read resources from THAT single server — no aggregate
    # global iteration, no per-resource registration bloat.
    #
    # Per-agent `mcp_servers` scoping works by construction because this tool
    # responds to `#mcp_server` (same seam as MCPToolWrapper), so
    # `Definition#reject_unscoped_mcp_tools` drops it just like any other
    # out-of-scope MCP tool.
    class McpResourceTool < Tools::Base
      attr_reader :server_name

      def initialize(client, server_name:)
        super()
        @client = client
        @server_name = server_name
      end

      # Collision-safe name that includes the server.  A server whose own
      # tool list includes the exact word "resources" would collide — the
      # manager guards against that with a one-line Registry check.
      def name
        "#{@server_name}_resources"[0, MCPToolWrapper::MAX_NAME_LENGTH]
      end

      def description
        "List or read resources exposed by the \"#{@server_name}\" MCP server. " \
          "Use action \"list\" to see available resources (uri, name, description), " \
          "and action \"read\" with a specific uri to fetch its content."
      end

      params do
        string :action, required: true, enum: %w[list read],
                        description: "Action: \"list\" to list resources, \"read\" to fetch one"
        string :uri, required: false, description: "Resource URI (required for \"read\")"
      end

      # Security: external MCP server data — medium risk, no sandbox.
      class ResourceSecurity < Tools::ToolSecurity
        def risk = :medium
        def risky? = true
        def sandbox = :none
      end

      security ResourceSecurity
      redaction_profile :shell # external content, fail-safe

      # Carried for the per-agent MCP scoping filter (Definition#reject_unscoped_mcp_tools).
      def mcp_server
        @server_name
      end

      def execute(action:, uri: nil)
        case action
        when "list"
          list_resources
        when "read"
          read_resource(uri)
        else
          "Error: unknown action \"#{action}\" — use \"list\" or \"read\"."
        end
      end

      private

      def list_resources
        resources = safe_resources
        return "No resources exposed by \"#{@server_name}\"." if resources.empty?

        lines = resources.map do |res|
          desc = res.description.to_s.empty? ? "-" : res.description.to_s
          mime = res.mime_type.to_s.empty? ? "(text)" : "(#{res.mime_type})"
          "  #{res.uri} — #{res.name} #{mime} — #{desc}"
        end

        "[#{@server_name}]\n#{lines.join("\n")}"
      end

      def read_resource(uri)
        return "Error: uri is required for \"read\" action." if uri.to_s.strip.empty?

        resource = find_resource(uri.to_s.strip)
        return "Error: no MCP resource found with uri \"#{uri}\"." unless resource

        content = resource.content.to_s
        return "Error: resource \"#{uri}\" returned empty content." if content.empty?

        content
      rescue StandardError => e
        "Error: MCP resource \"#{uri}\": #{e.message}"
      end

      def find_resource(uri)
        safe_resources.find { |r| r.uri == uri }
      end

      def safe_resources
        @client.resources
      rescue StandardError
        []
      end
    end
  end
end
