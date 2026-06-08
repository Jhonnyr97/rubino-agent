# frozen_string_literal: true

require "ruby_llm/mcp"

module Rubino
  module MCP
    # Manages multiple MCP client connections.
    # Reads server definitions from config, starts clients,
    # and registers their tools into the agent's tool registry.
    class Manager
      attr_reader :clients

      def initialize(config: nil)
        @config = config || Rubino.configuration
        @clients = {}
      end

      # Initializes all configured MCP servers
      def start_all!
        server_configs = @config.dig("mcp", "servers") || {}

        server_configs.each do |name, server_config|
          start_server(name, server_config)
        end

        register_all_tools!
        @clients
      end

      # Starts a single MCP server by name
      def start_server(name, server_config)
        transport = server_config["transport"] || "stdio"
        client_opts = build_client_options(name, transport, server_config)

        client = RubyLLM::MCP.client(**client_opts)
        @clients[name.to_s] = client

        Rubino.event_bus.emit(:mcp_server_started, name: name)
        client
      rescue StandardError => e
        Rubino.ui.warning("MCP server '#{name}' failed to start: #{e.message}")
        nil
      end

      # Stops all MCP clients
      def stop_all!
        @clients.each do |name, client|
          client.stop
          Rubino.event_bus.emit(:mcp_server_stopped, name: name)
        rescue StandardError => e
          Rubino.ui.warning("Error stopping MCP '#{name}': #{e.message}")
        end
        @clients.clear
      end

      # Stops a specific MCP client
      def stop_server(name)
        client = @clients.delete(name.to_s)
        client&.stop
      end

      # Returns all tools from all connected MCP servers
      def all_tools
        @clients.flat_map do |_name, client|
          client.tools
        rescue StandardError
          []
        end
      end

      # Returns tools scoped to a specific agent (based on agent config)
      # If the agent has mcp_servers defined, only those servers' tools are returned.
      def tools_for_agent(agent_definition)
        allowed_servers = agent_definition.respond_to?(:mcp_servers) ? agent_definition.mcp_servers : nil

        if allowed_servers.nil? || allowed_servers == :all
          all_tools
        else
          allowed_servers.flat_map do |server_name|
            client = @clients[server_name.to_s]
            client ? client.tools : []
          rescue StandardError
            []
          end
        end
      end

      # Registers all MCP tools into the agent's tool registry
      def register_all_tools!
        @clients.each do |server_name, client|
          client.tools.each do |mcp_tool|
            wrapped = MCPToolWrapper.new(mcp_tool, server_name: server_name)
            Tools::Registry.register(wrapped)
          end
        rescue StandardError => e
          Rubino.ui.warning("Failed to load tools from '#{server_name}': #{e.message}")
        end
      end

      # Checks health of all connected servers
      def health_check
        @clients.map do |name, client|
          alive = client.alive? rescue false
          { name: name, alive: alive }
        end
      end

      # Returns true if any MCP servers are configured
      def configured?
        servers = @config.dig("mcp", "servers")
        servers.is_a?(Hash) && !servers.empty?
      end

      private

      def build_client_options(name, transport, server_config)
        opts = {
          name: name.to_s,
          transport_type: transport.to_sym
        }

        case transport
        when "stdio"
          opts[:config] = {
            command: server_config["command"],
            args: server_config["args"] || [],
            env: server_config["env"] || {}
          }
        when "sse"
          opts[:config] = {
            url: server_config["url"],
            headers: server_config["headers"] || {}
          }
        when "streamable"
          opts[:config] = {
            url: server_config["url"],
            headers: server_config["headers"] || {}
          }
          if server_config["oauth"]
            opts[:config][:oauth] = server_config["oauth"]
          end
        end

        # Optional: request timeout
        if server_config["timeout"]
          opts[:request_timeout] = server_config["timeout"]
        end

        opts
      end
    end
  end
end
