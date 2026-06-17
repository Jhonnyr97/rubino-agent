# frozen_string_literal: true

module Rubino
  module Agent
    # Registry of all defined agents (primary, sub, utility).
    # Default agent system prompts are stored in agent/prompts/*.txt so they
    # can be edited without modifying Ruby source.
    class AgentRegistry
      PROMPTS_DIR = File.expand_path("prompts", __dir__)

      def initialize
        @agents = {}
        register_defaults!
      end

      # Returns all primary agents.
      def primary_agents
        @agents.values.select(&:primary?)
      end

      # Returns all visible subagents (for @mention).
      def subagents
        @agents.values.select { |a| a.subagent? && !a.hidden? }
      end

      # Returns all agents including hidden.
      def all
        @agents.values
      end

      # Finds an agent by name.
      def find(name)
        @agents[name.to_s]
      end

      # Registers a custom agent definition.
      def register(definition)
        @agents[definition.name] = definition
      end

      # Returns the default primary agent.
      def default
        find("build") || primary_agents.first
      end

      private

      def register_defaults!
        register(Definition.new(
                   name: "build",
                   type: :primary,
                   description: "Full-access development agent with all tools",
                   system_prompt: load_prompt("build"),
                   tools: :all
                 ))

        register(Definition.new(
                   name: "plan",
                   type: :primary,
                   description: "Read-only analysis and planning agent",
                   system_prompt: load_prompt("plan"),
                   tools: :read_only,
                   permissions: { "edit *" => "ask", "shell *" => "ask" }
                 ))

        register(Definition.new(
                   name: "explore",
                   type: :subagent,
                   description: "Fast read-only codebase exploration",
                   system_prompt: load_prompt("explore"),
                   tools: :read_only,
                   max_turns: 20
                 ))

        register(Definition.new(
                   name: "general",
                   type: :subagent,
                   description: "General-purpose agent for complex multi-step tasks",
                   system_prompt: load_prompt("general"),
                   tools: :all,
                   max_turns: 50
                 ))

        register(Definition.new(
                   name: "compaction",
                   type: :utility,
                   description: "Compresses long contexts",
                   system_prompt: load_prompt("compaction"),
                   hidden: true,
                   tools: []
                 ))

        register(Definition.new(
                   name: "title",
                   type: :utility,
                   description: "Generates session titles",
                   system_prompt: "Generate a concise title (max 6 words) for this conversation based on the first user message.",
                   hidden: true,
                   tools: []
                 ))
      end

      # Loads a prompt for a role. Checks the customer config for an
      # explicit override first (prompts.overrides.<role>) and falls back
      # to the built-in agent/prompts/<role>.txt. Missing files resolve
      # to an empty string so a stripped-down distribution doesn't crash
      # the registry at boot.
      def load_prompt(name)
        override = Rubino.configuration.prompts_override_for(name)
        return override if override

        path = File.join(PROMPTS_DIR, "#{name}.txt")
        # Read as UTF-8 explicitly: the built-in prompts carry non-ASCII glyphs
        # (em-dashes), so relying on the locale default_external crashes under a
        # bare C/POSIX locale (#273; consistent with #250/#251).
        File.exist?(path) ? File.read(path, encoding: "UTF-8").strip : ""
      rescue StandardError
        path = File.join(PROMPTS_DIR, "#{name}.txt")
        File.exist?(path) ? File.read(path, encoding: "UTF-8").strip : ""
      end
    end
  end
end
