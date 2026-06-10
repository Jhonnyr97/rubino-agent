# frozen_string_literal: true

module Rubino
  # MCP (Model Context Protocol) integration module.
  # Manages connections to MCP servers and exposes their tools
  # to the agent via the standard Tools::Registry.
  module MCP
    class << self
      # The shared, booted Manager (nil until boot! succeeds).
      attr_reader :manager

      # MCP is opt-in by configuration (#95): a non-empty `mcp.servers`
      # block enables it; an explicit `mcp.enabled: false` switches it off
      # without deleting the server definitions.
      def enabled?(config = Rubino.configuration)
        servers = config.dig("mcp", "servers")
        return false unless servers.is_a?(Hash) && !servers.empty?

        config.dig("mcp", "enabled") != false
      end

      # Boots the shared Manager once per process: connects to every
      # configured server and registers their prefixed tools in
      # Tools::Registry (#91). Best-effort — MCP is an optional
      # integration and must never break boot, so any failure is a
      # warning, not an error.
      def boot!
        return @manager if @manager
        return nil unless enabled?

        manager = Manager.new
        manager.start_all!
        @manager = manager
      rescue StandardError => e
        Rubino.ui.warning("MCP startup failed: #{e.message}")
        nil
      end

      # Clears the booted Manager (used by tests).
      def reset!
        @manager = nil
      end
    end
  end
end
