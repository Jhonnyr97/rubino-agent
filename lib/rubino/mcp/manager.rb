# frozen_string_literal: true

require "ruby_llm/mcp"

module Rubino
  module MCP
    # Manages multiple MCP client connections.
    # Reads server definitions from config, starts clients,
    # and registers their tools into the agent's tool registry.
    class Manager
      # clients: name => live RubyLLM::MCP client.
      # last_errors: name => the most recent start failure message (cleared on a
      # successful start) — the "why is my server missing?" answer /mcp's
      # drill-in shows (#182).
      attr_reader :clients, :last_errors

      def initialize(config: nil)
        @config = config || Rubino.configuration
        @clients = {}
        @last_errors = {}
        # Guards @clients / @last_errors writes during the PARALLEL connect phase
        # (start_all!). The single-server path (start_server) takes it too, so the
        # invariant "shared-state mutations are serialized" holds on every caller.
        @state_mutex = Mutex.new
        route_mcp_logging!
      end

      # Initializes all configured MCP servers.
      #
      # The connect handshake is the slow part: each RubyLLM::MCP.client(**opts)
      # blocks up to the per-server request_timeout (default 8 s) while it spawns
      # the child / opens the socket and waits for `initialize`. Done SERIALLY, N
      # hanging servers cost the SUM of their timeouts (#576 measured 17.6 s with
      # two stalling servers). So we connect every server CONCURRENTLY — one
      # thread each (the count is small and these threads are I/O-bound) — which
      # bounds total connect time to roughly the slowest SINGLE server.
      #
      # Thread-safety: each thread only does the network/subprocess connect and
      # writes its result into @clients/@last_errors UNDER @state_mutex (plain
      # Hashes are not thread-safe). Tool registration is deferred to the MAIN
      # thread (register_all_tools! below, after every join) because
      # Tools::Registry is a process-wide singleton over a plain Hash and is NOT
      # thread-safe. Best-effort semantics are preserved: start_server rescues
      # per-server, so one server raising/stalling never aborts the others.
      def start_all!
        server_configs = @config.dig("mcp", "servers") || {}

        threads = server_configs.map do |name, server_config|
          Thread.new { start_server(name, server_config) }
        end
        threads.each(&:join)

        register_all_tools!
        @clients
      end

      # Starts a single MCP server by name
      def start_server(name, server_config)
        transport = server_config["transport"] || "stdio"
        client_opts = build_client_options(name, transport, server_config)

        # The slow, blocking connect runs OUTSIDE the lock so concurrent
        # start_all! threads actually overlap; only the shared-Hash writes are
        # serialized under @state_mutex.
        client = RubyLLM::MCP.client(**client_opts)
        @state_mutex.synchronize do
          @clients[name.to_s] = client
          @last_errors.delete(name.to_s)
        end

        register_notification_handlers(client, name.to_s)

        Rubino.event_bus.emit(:mcp_server_started, name: name)
        client
      rescue StandardError => e
        @state_mutex.synchronize { @last_errors[name.to_s] = e.message }
        Rubino.ui.warning("MCP server '#{name}' failed to start: #{e.message}")
        nil
      end

      # Stops all MCP clients (deregistering their tools — see #stop_server).
      # `keys.each`, NOT `each_key`: stop_server deletes from @clients, which
      # would raise mid-iteration without the snapshot.
      def stop_all!
        @clients.keys.each { |name| stop_server(name) } # rubocop:disable Style/HashEachMethods
      end

      # Stops a specific MCP client AND deregisters its MCPToolWrapper
      # instances from Tools::Registry (#182) — before, nothing ever
      # unregistered them, so a stopped server left dead tools the model could
      # still call.
      def stop_server(name)
        client = @clients.delete(name.to_s)
        return nil unless client

        deregister_tools(name.to_s)
        begin
          client.stop
        rescue StandardError => e
          Rubino.ui.warning("Error stopping MCP '#{name}': #{e.message}")
        end
        Rubino.event_bus.emit(:mcp_server_stopped, name: name)
        client
      end

      # Registers all MCP tools into the agent's tool registry.
      # Per-agent mcp_servers scoping is NOT applied here — it lives in
      # Agent::Definition#resolved_tools (#173), the single seam every
      # consumer of an agent's tool set goes through.
      # Registers in a STABLE order (sorted by server name) rather than @clients'
      # insertion order — under the parallel start_all! @clients is populated in
      # connect-COMPLETION order, which is nondeterministic. Sorting keeps the
      # resulting tool-registration order (and anything downstream that reads it)
      # deterministic across boots.
      def register_all_tools!
        @clients.keys.sort.each { |server_name| register_server_tools(server_name) }
      end

      # Registers ONE started server's tools — the `/mcp <server> on` path
      # (#182) re-registers only that server instead of re-reading every
      # client's tool list.
      def register_server_tools(name)
        client = @clients[name.to_s]
        return unless client

        client.tools.each do |mcp_tool|
          wrapped = MCPToolWrapper.new(mcp_tool, server_name: name.to_s)
          Tools::Registry.register(wrapped)
        end

        # Per-server resource tool — registered only when the server advertises
        # the resources capability, alongside the tool wrappers so per-agent
        # mcp_servers scoping drops it by construction (same #mcp_server seam).
        # Skip if a real tool's prefixed name would collide.
        if client.capabilities.resources_list?
          resource_tool = McpResourceTool.new(client, server_name: name.to_s)
          Tools::Registry.register(resource_tool) unless Tools::Registry.find(resource_tool.name)
        end

        # Per-server prompt tool — same pattern as the resource tool, gated on
        # the prompts capability advertised at initialize.
        if client.capabilities.prompt_list?
          prompt_tool = McpPromptTool.new(client, server_name: name.to_s)
          Tools::Registry.register(prompt_tool) unless Tools::Registry.find(prompt_tool.name)
        end

        # A clean tools/list clears any prior failure so a recovered server
        # stops showing degraded (mirrors start_server clearing on success).
        @last_errors.delete(name.to_s)
      rescue StandardError => e
        # Record the failure so /mcp's drill-in (and the degraded glyph below)
        # can explain a connected-but-toolless server (#575) — start_server
        # records start failures the same way; a swallowed warning alone left
        # the broken state invisible.
        @last_errors[name.to_s] = e.message
        Rubino.ui.warning("Failed to load tools from '#{name}': #{e.message}")
      end

      # Checks health of all connected servers. `alive` is process-liveness
      # (the child is up); `degraded` is protocol-liveness (#575): the process
      # is alive but tools/list/registration failed, so a recorded last_error
      # exists despite a live client. Callers render degraded distinctly from
      # plain reachable — an alive server that legitimately exposes zero tools
      # has NO last_error and is NOT degraded.
      def health_check
        @clients.map do |name, client|
          alive = begin
            client.alive?
          rescue StandardError
            false
          end
          { name: name, alive: alive, degraded: alive && @last_errors.key?(name.to_s) }
        end
      end

      # Returns true if any MCP servers are configured
      def configured?
        servers = @config.dig("mcp", "servers")
        servers.is_a?(Hash) && !servers.empty?
      end

      private

      # Drops a stopped server's wrappers AND resource tool from the registry
      # (keyed by the prefixed name, so only that server's entries match).
      def deregister_tools(server_name)
        Tools::Registry.all.each do |tool|
          next unless tool.respond_to?(:mcp_server) && tool.mcp_server == server_name

          Tools::Registry.unregister(tool.name)
        end
      end

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

      # Registers per-server progress and logging notification handlers
      # that write to the MCP log file. Each handler is independently
      # guarded so a server that doesn't support the feature never
      # breaks startup. The callbacks fire on the client's background
      # transport thread; writing to a Ruby Logger is thread-safe.
      def register_notification_handlers(client, name)
        logger = mcp_logger

        begin
          # Use the gem default log level (RubyLLM::MCP::Logging::WARNING = "warning")
          # so we capture notable server warnings/errors without flooding mcp.log
          # with debug/info/notice traffic on every tool call.
          client.on_logging do |notification|
            level = notification.params["level"]
            origin = notification.params["logger"]
            data = notification.params["data"]
            logger.info("[#{name}] #{level}: #{origin}: #{data}")
          end
        rescue StandardError => e
          logger.debug("[#{name}] logging notifications unsupported: #{e.message}")
        end

        begin
          client.on_progress do |progress|
            total_str = progress.total ? "/#{progress.total}" : ""
            msg_str = progress.message ? " — #{progress.message}" : ""
            logger.info("[#{name}] progress #{progress.progress}#{total_str}#{msg_str}")
          end
        rescue StandardError => e
          logger.debug("[#{name}] progress tracking unsupported: #{e.message}")
        end
      end

      # Returns the MCP log path under the rubino home, matching
      # route_mcp_logging! so the same file is always used.
      def mcp_log_path
        File.join(Config::Loader.default_home_path, "logs", "mcp.log")
      end

      # Returns the MCP logger (already routed to mcp.log by the
      # constructor); falls back to a fresh Logger at the same path.
      def mcp_logger
        RubyLLM::MCP.config.logger || ::Logger.new(mcp_log_path)
      rescue StandardError
        ::Logger.new($stdout)
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
            args: validate_stdio_args!(name, server_config["args"]),
            env: server_config["env"] || {}
          }
        when "sse", "streamable"
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

      # stdio `args` MUST be a list (YAML sequence). A STRING — the natural typo,
      # `args: "--root /data"` instead of `args: ["--root", "/data"]` — used to be
      # passed straight to ruby_llm-mcp, which iterated the string into single
      # characters, spawned a broken process, and surfaced ~8s later as a
      # misleading "timed out" (the spawn never spoke MCP). Reject it HERE so
      # start_server's rescue turns it into an immediate, clear config error
      # instead of a hang. nil ⇒ no args (default []).
      def validate_stdio_args!(name, args)
        return [] if args.nil?
        return args if args.is_a?(Array)

        raise ArgumentError,
              "MCP server '#{name}': `args` must be a list, got #{args.class} " \
              "(#{args.inspect}). Use a YAML sequence, e.g. " \
              "args: [\"--root\", \"/data\"] (not a single string)."
      end
    end
  end
end
