# frozen_string_literal: true

module Rubino
  module CLI
    # Lists available tools and their status
    class ToolsCommand
      def execute
        ui = Rubino.ui
        config = Rubino.configuration

        ui.info("Available Tools:")
        ui.blank_line

        # The registry is populated lazily when an agent runner boots; the bare
        # `rubino tools` command never boots one, so without this the table
        # is empty (F6). Registering the defaults is idempotent and matches what
        # ChatCommand#ensure_setup! does before a turn.
        Tools::Registry.register_defaults! if Tools::Registry.all.empty?

        # Report against the SAME config gate the registry enforces: each row
        # is a `tools.<config_key>` group, resolved exactly like
        # Registry#tool_enabled_in_config? (opt-out — absent key = enabled).
        # Deriving the rows from the registered tools' #config_key (rather
        # than a hardcoded list) means the displayed state can never drift
        # from reality — `web` no longer shows "disabled" while webfetch/
        # websearch stay live, and the dead `browser` key is gone.
        # MCP wrappers are excluded here: they are dynamic (no `tools.<key>`
        # config gate) and get their own section below instead of fake rows
        # in the config-group table.
        builtins = Tools::Registry.all.grep_v(MCP::MCPToolWrapper)
        config_keys = builtins.map(&:config_key).uniq
        rows = config_keys.sort.map do |key|
          value   = config.dig("tools", key)
          enabled = value.nil? || value == true
          [key, enabled ? "enabled" : "disabled"]
        end

        ui.table(headers: %w[Tool Status], rows: rows)

        print_enable_hint(rows)
        print_mcp_tools
      end

      private

      # A disabled row with no pointer is a dead end (#20): name the exact
      # config command that turns the group back on.
      def print_enable_hint(rows)
        disabled = rows.select { |_, status| status == "disabled" }.map(&:first)
        return if disabled.empty?

        ui = Rubino.ui
        ui.blank_line
        ui.info("Enable with: rubino config set tools.<name> true   (e.g. tools.#{disabled.first})")
      end

      # Lists tools from configured MCP servers (#91). Configuring
      # `mcp.servers` is the opt-in: the Manager connects, prefixes each tool
      # `servername_toolname`, and registers it alongside the built-ins. A
      # configured-but-empty result still prints a breadcrumb (#94) so MCP
      # users are never left staring at a silently builtin-only table —
      # unreachable servers additionally warn via Manager#start_server.
      def print_mcp_tools
        return unless MCP.enabled?

        ui = Rubino.ui
        ui.blank_line
        ui.info("MCP Tools (experimental):")
        MCP.boot!

        mcp_tools = Tools::Registry.all.grep(MCP::MCPToolWrapper)
        if mcp_tools.empty?
          ui.warning("mcp.servers configured, but no MCP tools loaded")
        else
          rows = mcp_tools.map { |t| [t.name, t.server_name] }.sort
          ui.table(headers: %w[Tool Server], rows: rows)
        end
      end
    end
  end
end
