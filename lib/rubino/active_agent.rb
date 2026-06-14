# frozen_string_literal: true

module Rubino
  # In-process slot holding the ONE primary agent the user has switched to for
  # this session. Mirrors Rubino::Modes / Rubino::ActiveSkill: a process-level
  # slot, set via the `/agent <name>` picker (or a bare `/<name>` for a primary)
  # and cycled with Tab. The selected agent's Definition (its system prompt and
  # tool scope) is threaded into the runner each turn, so the choice actually
  # changes the model's persona/tools — not just a cosmetic chip.
  #
  # Lives at the process level intentionally — alpha rule: no premature
  # persistence. A fresh `rubino chat` boots on the registry default ("build");
  # an explicit switch takes effect for the rest of that process.
  #
  # The slot stores the agent NAME (a String); resolution to a Definition goes
  # through Rubino.agent_registry so a freshly registered/overridden agent is
  # always reflected. Only PRIMARY agents are switchable here — subagents
  # (explore/general) are invoked one-shot via `/<name> <message>`, never pinned.
  module ActiveAgent
    class << self
      # The pinned primary-agent name (String). Defaults to the registry's
      # default primary on first read.
      def current
        @current ||= default_name
      end

      # Pins +name+ as the active primary agent. Validates against the
      # registry's primary agents and raises on an unknown/non-primary name so a
      # typo surfaces immediately (parity with Modes.set). Returns the new name.
      def set(name)
        candidate = name.to_s.strip
        agent = Rubino.agent_registry.find(candidate)
        unless agent&.primary?
          raise ArgumentError,
                "unknown primary agent: #{name.inspect} (valid: #{names.join(", ")})"
        end

        @current = agent.name
      end

      # The resolved Definition for the current agent, or nil if it has since
      # gone missing (defensive — the registry is stable within a process).
      def definition
        Rubino.agent_registry.find(current)
      end

      # The names of all switchable (primary) agents, in registry order.
      def names
        Rubino.agent_registry.primary_agents.map(&:name)
      end

      # Cycle to the NEXT primary agent (Tab). Wraps around. Returns the new
      # name. No-op-safe when only one primary agent exists.
      def cycle
        all = names
        return current if all.empty?

        idx = all.index(current) || -1
        @current = all[(idx + 1) % all.length]
      end

      # The registry default primary name, used as the initial value.
      def default_name
        Rubino.agent_registry.default&.name
      end

      # Test/teardown hook. Not part of the public API.
      def reset!
        @current = nil
      end
    end
  end
end
