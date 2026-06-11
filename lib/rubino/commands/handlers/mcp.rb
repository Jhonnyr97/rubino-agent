# frozen_string_literal: true

require "pastel"

module Rubino
  module Commands
    module Handlers
      # The `/mcp` in-chat management of MCP servers (#182), extracted from
      # Commands::Executor (batch B). Shaped like /skills:
      #
      #   /mcp                 → server list: status, transport, tool count
      #   /mcp <server>        → drill-in: transport/target, health, its tools
      #   /mcp <server> off    → stop the client + deregister its tools (session)
      #   /mcp <server> on     → (re)start the client + register its tools
      #   /mcp reload          → re-read config.yml and reconnect every server
      #
      # List/drill-in read the LIVE booted manager (Rubino::MCP.manager) and
      # never re-spawn stdio servers — doctor's start/stop dance is wrong inside
      # a session that already holds clients. `off` is session-scoped, like
      # /skills activation; persistent disable stays a config edit (mcp.enabled
      # or removing the server).
      class MCP
        def initialize(ui:)
          @ui = ui
        end

        def handle_mcp(arguments)
          server, action = arguments.to_s.strip.split(/\s+/)
          # reload must work BEFORE the enabled? gate: its whole point is picking
          # up a config edit (e.g. a first server added mid-session).
          return reload_mcp if server == "reload"

          unless Rubino::MCP.enabled?
            show_mcp_empty_state
            return
          end

          server.nil? ? show_mcp_list : handle_mcp_server(server, action)
        end

        private

        # The two empty states the issue calls out: no servers at all vs the
        # mcp.enabled kill switch.
        # Empty states are quiet facts, not successes/calls-to-celebrate:
        # dim, never colored (P8).
        def show_mcp_empty_state
          if mcp_servers_config.any?
            @ui.status("MCP is disabled (mcp.enabled: false in config.yml) — " \
                       "#{mcp_servers_config.size} server(s) defined but not started.")
          else
            @ui.status("No MCP servers configured.")
            @ui.status("Add an mcp.servers block to config.yml (see docs/mcp.md), then /mcp reload.")
          end
        end

        def show_mcp_list
          mcp_servers_config.each do |name, server_config|
            tools = mcp_tools_for(name).size
            @ui.panel_line(name, "(#{server_config["transport"] || "stdio"})  " \
                                 "#{mcp_status_icon(name)}  ·  #{tools} tool#{"s" if tools != 1}")
          end
          @ui.status("/mcp <server> for its tools   ·   /mcp <server> on|off   ·   /mcp reload")
        end

        def handle_mcp_server(name, action)
          unless mcp_servers_config.key?(name)
            @ui.error("unknown MCP server: #{name}")
            @ui.info("Configured: #{mcp_servers_config.keys.join(", ")}")
            return
          end

          case action
          when nil   then show_mcp_server(name)
          when "off" then mcp_server_off(name)
          when "on"  then mcp_server_on(name)
          else
            @ui.error("unknown /mcp action: #{action}")
            @ui.info("Usage: /mcp #{name} [on|off]")
          end
        end

        def show_mcp_server(name)
          server_config = mcp_servers_config[name]
          transport     = server_config["transport"] || "stdio"
          target        = if transport == "stdio"
                            [server_config["command"], *Array(server_config["args"])].join(" ")
                          else
                            server_config["url"].to_s
                          end

          @ui.info("#{name}  #{mcp_status_icon(name)}")
          @ui.panel_line("transport", "#{transport}  ·  #{target}")
          last_error = Rubino::MCP.manager&.last_errors&.dig(name)
          @ui.panel_line("last error", last_error) if last_error
          show_mcp_server_tools(name)
        end

        # The server's registered tools (prefixed names + descriptions), wrapped
        # like the /skills list so long descriptions never hard-break mid-word.
        def show_mcp_server_tools(name)
          tools = mcp_tools_for(name)
          if tools.empty?
            @ui.info("  tools      (none registered — /mcp #{name} on to start it)")
            return
          end

          @ui.info("  tools      #{tools.size}:")
          tools.each do |tool|
            wrap_skill_line("    #{tool.name} - ", tool.description.to_s).each { |line| @ui.info(line) }
          end
        end

        # Session-scoped disable: stop the client AND drop its wrappers from the
        # registry (Manager#stop_server deregisters — #182), so the model stops
        # seeing tools whose client is gone.
        def mcp_server_off(name)
          manager = Rubino::MCP.manager
          if manager.nil? || !manager.clients.key?(name)
            @ui.info("MCP server #{name} is not running.")
            return
          end

          removed = mcp_tools_for(name).size
          manager.stop_server(name)
          @ui.success("MCP server #{name} stopped — #{removed} tool#{"s" if removed != 1} removed " \
                      "for this session (/mcp #{name} on to restart; config untouched).")
        end

        # (Re)start one server and register its tools. With no booted manager yet
        # (MCP never enabled at boot, or boot failed), boot! brings the whole
        # subsystem up — which starts this server too.
        def mcp_server_on(name)
          manager = Rubino::MCP.manager || Rubino::MCP.boot!
          unless manager
            @ui.error("could not boot MCP — check mcp.servers in config.yml, or /mcp reload")
            return
          end

          manager.stop_server(name) if manager.clients.key?(name)
          # start_server already warned with the failure detail; just point at it.
          return @ui.error("could not start MCP server #{name} (see warning above)") unless
            manager.start_server(name, mcp_servers_config[name])

          manager.register_server_tools(name)
          count = mcp_tools_for(name).size
          @ui.success("MCP server #{name} started — #{count} tool#{"s" if count != 1} registered.")
        end

        def reload_mcp
          manager = Rubino::MCP.reload!
          if manager.nil?
            show_mcp_empty_state
            return
          end

          @ui.success("MCP reloaded.")
          show_mcp_list
        end

        # `<glyph> <word>` for a server's state (colored like agent_status_icon):
        # green ● reachable, red ✗ down, yellow ◌ not started (no live client).
        def mcp_status_icon(name)
          entry = mcp_health.find { |h| h[:name] == name }
          glyph, word, color =
            if entry.nil? then ["◌", "not started", :yellow]
            elsif entry[:alive] then ["●", "reachable", :green]
            else ["✗", "down", :red]
            end
          "#{pastel.public_send(color, glyph)} #{word}"
        end

        # The configured mcp.servers block (name => config), {} when absent.
        def mcp_servers_config
          Rubino.configuration.dig("mcp", "servers") || {}
        end

        # Live reachability from the booted manager; [] when MCP never booted.
        # Manager#health_check already rescues per client, so a wedged transport
        # reports alive: false instead of raising.
        def mcp_health
          Rubino::MCP.manager&.health_check || []
        end

        # The registry wrappers a server contributed (prefixed tools).
        def mcp_tools_for(server_name)
          Tools::Registry.all.select do |tool|
            tool.is_a?(Rubino::MCP::MCPToolWrapper) && tool.server_name == server_name
          end
        end

        # Wraps "<head><description>" to the terminal width, breaking only on
        # whitespace, with continuation lines indented to the description column.
        def wrap_skill_line(head, description)
          width = terminal_width
          indent = " " * head.length
          avail  = [width - head.length, 20].max

          lines = []
          current = +""
          description.split(/\s+/).each do |word|
            candidate = current.empty? ? word : "#{current} #{word}"
            if candidate.length > avail && !current.empty?
              lines << current
              current = word.dup
            else
              current = candidate
            end
          end
          lines << current unless current.empty?
          lines = [""] if lines.empty?

          lines.each_with_index.map { |line, i| (i.zero? ? head : indent) + line }
        end

        def pastel
          @pastel ||= Pastel.new
        end

        def terminal_width
          cols = IO.console&.winsize&.last
          cols&.positive? ? cols : 80
        rescue StandardError
          80
        end
      end
    end
  end
end
