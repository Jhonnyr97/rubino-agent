# frozen_string_literal: true

module Rubino
  module Agent
    # Resolves which agent Definition a turn runs under.
    #
    # Bare-`@` agent routing was REMOVED (#320): `@` is the FILE picker, so a
    # filename like `@explore.rb` must never be shadowed by an agent named
    # "explore". Agent switching now lives entirely on the slash channel
    # (`/agent <name>`, a bare `/<name>` for a primary, a one-shot
    # `/<name> <message>` for any agent) and on Tab-cycling — see
    # Rubino::ActiveAgent and CLI::ChatCommand. This Router stays a thin,
    # registry-backed helper for selecting/cycling the sticky PRIMARY agent.
    class Router
      def initialize(registry:, ui:)
        @registry = registry
        @ui = ui
        @current_agent = registry.default
      end

      attr_reader :current_agent

      # Switches to a different primary agent (the sticky `/agent <name>`).
      def switch_to(agent_name)
        agent = @registry.find(agent_name)
        unless agent
          @ui.error("unknown agent: #{agent_name}")
          return false
        end

        unless agent.primary?
          @ui.error("cannot switch to subagent '#{agent_name}'. Use /#{agent_name} <message> to invoke it.")
          return false
        end

        @current_agent = agent
        @ui.info("Switched to agent: #{agent.name}")
        true
      end

      # Cycles to the next primary agent (Tab), wrapping around. Returns the new
      # Definition.
      def cycle
        primaries = @registry.primary_agents
        return @current_agent if primaries.empty?

        idx = primaries.index { |a| a.name == @current_agent&.name } || -1
        @current_agent = primaries[(idx + 1) % primaries.length]
      end

      # Returns primary agent names for switching.
      def switchable_agents
        @registry.primary_agents.map(&:name)
      end
    end
  end
end
