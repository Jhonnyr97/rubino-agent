# frozen_string_literal: true

module Rubino
  module Commands
    module Handlers
      # The PRIMARY-agent switcher (#320), distinct from Handlers::Agents (which
      # drills into the background `task` subagents). Resolves the `/agent`
      # picker and the dynamic `/<agent-name>` commands against the live
      # Rubino.agent_registry, returning the dispatcher's signal vocabulary:
      #
      #   {select_agent: name}   pin a primary agent for the session (sticky)
      #   {prompt:, agent:}      route THIS turn to an agent (one-shot)
      #   :handled               listing / usage hint, no turn and no switch
      #
      # The REPL applies {select_agent:} to the live runner + Rubino::ActiveAgent
      # and threads {agent:} through run_turn — the same channel a custom
      # command's `agent:` frontmatter already used.
      class AgentSwitch
        def initialize(ui:)
          @ui = ui
        end

        # `/agent`        → list switchable primaries + invokable subagents
        # `/agent <name>` → pin a primary (returns a {select_agent:} signal)
        def handle_picker(arguments)
          name = arguments.to_s.strip.split(/\s+/).first

          if name.nil? || name.empty? || name == "list"
            show_roster
            return :handled
          end

          agent = registry.find(name)
          unless agent&.primary?
            reject_non_primary(name, agent)
            return :handled
          end

          { select_agent: agent.name }
        end

        # Resolves a dynamic `/<agent-name>` command. Returns nil when +name+ is
        # not a visible agent (so the dispatcher falls through to custom
        # commands), a {select_agent:} sticky switch for a bare primary, a
        # {prompt:, agent:} one-shot route when a message follows, or :handled
        # with a usage hint for a bare subagent name.
        def handle_command(name, arguments)
          agent = registry.find(name)
          return nil unless agent && !agent.hidden?

          message = arguments.to_s.strip
          return route_bare(name, agent) if message.empty?

          # One-shot route: this turn runs under <agent>'s definition.
          @ui.status("Routing this turn to agent: /#{name}")
          { prompt: message, agent: agent.name }
        end

        private

        def registry
          Rubino.agent_registry
        end

        def route_bare(name, agent)
          return { select_agent: agent.name } if agent.primary?

          @ui.info("/#{name} is a subagent — give it a task: /#{name} <message>.")
          :handled
        end

        def reject_non_primary(name, agent)
          if agent
            @ui.info("'#{name}' is a subagent — invoke it one-shot with /#{name} <message>.")
          else
            @ui.error("unknown agent: #{name}")
            @ui.info("Available: #{registry.primary_agents.map(&:name).join(", ")}")
          end
        end

        # The `/agent` listing: primaries (switchable, current marked) then the
        # invokable subagents, mirroring /mode's roster style.
        def show_roster
          current = Rubino::ActiveAgent.current
          @ui.info("Primary agents (switch with /agent <name>, a bare /<name>, or Tab):")
          registry.primary_agents.each do |a|
            marker = a.name == current ? "▸" : " "
            @ui.info("  #{marker} /#{a.name} — #{a.description}")
          end
          subs = registry.subagents
          return if subs.empty?

          @ui.blank_line
          @ui.info("Subagents (one-shot: /<name> <message>):")
          subs.each { |a| @ui.info("    /#{a.name} — #{a.description}") }
        end
      end
    end
  end
end
