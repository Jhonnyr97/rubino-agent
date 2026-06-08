# frozen_string_literal: true

module Rubino
  module Agent
    # Defines an agent type with its own model, system prompt, permissions, and tools.
    # Agents can be primary (user-facing) or subagents (invokable by other agents).
    class Definition
      attr_reader :name, :type, :model, :system_prompt, :description,
                  :permissions, :tools, :hidden, :mcp_servers

      # Types: :primary (user-switchable), :subagent (invokable), :utility (hidden)
      TYPES = %i[primary subagent utility].freeze

      def initialize(attrs = {})
        @name = attrs[:name]
        @type = attrs[:type] || :primary
        @model = attrs[:model]
        @system_prompt = attrs[:system_prompt]
        @description = attrs[:description] || ""
        @permissions = attrs[:permissions] || {}
        @mcp_servers = attrs[:mcp_servers] || :all # :all or array of server names
        @tools = attrs[:tools] || :all # :all, :read_only, or array of tool names
        @hidden = attrs[:hidden] || false
        @max_turns = attrs[:max_turns]
      end

      def primary?
        @type == :primary
      end

      def subagent?
        @type == :subagent
      end

      def utility?
        @type == :utility
      end

      def hidden?
        @hidden
      end

      # Returns the max turns for this agent (falls back to global config)
      def max_turns
        @max_turns || Rubino.configuration.agent_max_turns
      end

      # Returns the resolved model (falls back to global default)
      def resolved_model
        @model || Rubino.configuration.model_default
      end

      # Returns tool list based on the agent's tool configuration.
      #
      # No-nesting guard: a subagent NEVER gets the delegation tools (`task` and
      # its companions `task_result`/`task_stop`), regardless of its tool config
      # (:all / :read_only / explicit list) — a subagent must not spawn or steer
      # further subagents. This is the single enforcement point; #resolved_tools
      # is what Lifecycle#load_tools hands to the loop, so a subagent run can't
      # even propose a `task` call.
      DELEGATION_TOOLS = %w[task task_result task_stop].freeze

      def resolved_tools
        tools =
          case @tools
          when :all
            Tools::Registry.enabled_tools
          when :read_only
            Tools::Registry.enabled_tools.select { |t| t.risk_level == :low }
          when Array
            @tools.filter_map { |name| Tools::Registry.find(name) }
          else
            Tools::Registry.enabled_tools
          end

        subagent? ? tools.reject { |t| DELEGATION_TOOLS.include?(t.name) } : tools
      end
    end
  end
end
