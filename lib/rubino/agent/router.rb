# frozen_string_literal: true

module Rubino
  module Agent
    # Routes user input to the appropriate agent.
    # Handles @mention syntax for subagent invocation and agent switching.
    class Router
      MENTION_REGEX = /\A@(\w+)\s+(.+)/m

      def initialize(registry:, ui:)
        @registry = registry
        @ui = ui
        @current_agent = registry.default
      end

      attr_reader :current_agent

      # Switches to a different primary agent
      def switch_to(agent_name)
        agent = @registry.find(agent_name)
        unless agent
          @ui.error("unknown agent: #{agent_name}")
          return false
        end

        unless agent.primary?
          @ui.error("cannot switch to subagent '#{agent_name}'. Use @#{agent_name} to invoke it.")
          return false
        end

        @current_agent = agent
        @ui.info("Switched to agent: #{agent.name}")
        true
      end

      # Routes input, returning [agent_definition, cleaned_input]
      def route(input)
        # Check for @mention
        if input.match?(MENTION_REGEX)
          match = input.match(MENTION_REGEX)
          agent_name = match[1]
          actual_input = match[2]

          agent = @registry.find(agent_name)
          return [agent, actual_input] if agent && (agent.subagent? || agent.primary?)

          @ui.warning("Unknown agent '#{agent_name}', using current agent")

        end

        [@current_agent, input]
      end

      # Returns available agent names for autocomplete
      def available_mentions
        @registry.subagents.map { |a| "@#{a.name}" }
      end

      # Returns primary agent names for switching
      def switchable_agents
        @registry.primary_agents.map(&:name)
      end
    end
  end
end
