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
        config_keys = Tools::Registry.all.map(&:config_key).uniq
        rows = config_keys.sort.map do |key|
          value   = config.dig("tools", key)
          enabled = value.nil? || value == true
          [key, enabled ? "enabled" : "disabled"]
        end

        ui.table(headers: %w[Tool Status], rows: rows)
      end
    end
  end
end
