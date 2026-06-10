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
        route_mcp_logging!
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

      # Registers all MCP tools into the agent's tool registry.
      # Per-agent mcp_servers scoping is NOT applied here — it lives in
      # Agent::Definition#resolved_tools (#173), the single seam every
      # consumer of an agent's tool set goes through.
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
          alive = begin
            client.alive?
          rescue StandardError
            false
          end
          { name: name, alive: alive }
        end
      end

      # Returns true if any MCP servers are configured
      def configured?
        servers = @config.dig("mcp", "servers")
        servers.is_a?(Hash) && !servers.empty?
      end

      private

      # ruby_llm-mcp logs to $stdout by default — including every line the
      # stdio server prints on ITS stderr (e.g. "Secure MCP Filesystem Server
      # running on stdio"), relayed at INFO. That raw logger line pollutes
      # one-shot `rubino prompt` output, doctor, tools and the chat banner
      # (#174 — same class as the fixed #99). Route the gem's logger to a file
      # under the resolved home, next to RUBYLLM_DEBUG's ruby_llm.log.
      def route_mcp_logging!
        log_path = File.join(Config::Loader.default_home_path, "logs", "mcp.log")
        FileUtils.mkdir_p(File.dirname(log_path))
        RubyLLM::MCP.config.logger = ::Logger.new(log_path, progname: "RubyLLM::MCP", level: ::Logger::INFO)
      rescue StandardError
        # Logging is never worth breaking MCP boot; worst case the gem keeps
        # its default logger.
        nil
      end

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
          opts[:config][:oauth] = server_config["oauth"] if server_config["oauth"]
        end

        # Optional: request timeout
        opts[:request_timeout] = server_config["timeout"] if server_config["timeout"]

        opts
      end
    end
  end
end
