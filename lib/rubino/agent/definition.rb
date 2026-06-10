# frozen_string_literal: true

module Rubino
  module Agent
    # Defines an agent type with its own model, system prompt, permissions, and tools.
    # Agents can be primary (user-facing) or subagents (invokable by other agents).
    class Definition
      attr_reader :name, :type, :model, :system_prompt, :description,
                  :permissions, :tools, :hidden

      # Types: :primary (user-switchable), :subagent (invokable), :utility (hidden)
      TYPES = %i[primary subagent utility].freeze

      def initialize(attrs = {})
        @name = attrs[:name]
        @type = attrs[:type] || :primary
        @model = attrs[:model]
        @system_prompt = attrs[:system_prompt]
        @description = attrs[:description] || ""
        @permissions = attrs[:permissions] || {}
        @mcp_servers = attrs[:mcp_servers] # :all or array of server names
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

      # Which MCP servers this agent may use: :all, or an array of server
      # names. An explicit value passed in code wins; otherwise the
      # `agents.<name>.mcp_servers` block in config.yml applies (#92), and
      # absent both the agent sees every server. YAML has no symbols, so the
      # literal string "all" from config normalizes to :all — the value
      # MCP::Manager#tools_for_agent compares against.
      def mcp_servers
        return @mcp_servers if @mcp_servers

        configured = Rubino.configuration.dig("agents", name.to_s, "mcp_servers")
        case configured
        when Array then configured.map(&:to_s)
        else :all
        end
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
      # Scoped nesting (S1): a subagent now KEEPS the delegation tools (`task` and
      # its companions `task_result`/`task_stop`) so it can spawn its own
      # subagents. Runaway recursion / fan-out is no longer prevented by hiding
      # the tool here — it is bounded in ONE place, Tools::BackgroundTasks#reserve,
      # by the depth / per-owner / global caps. (DELEGATION_TOOLS is kept as a
      # named set for any reader that still wants to reason about the group.)
      DELEGATION_TOOLS = %w[task task_result task_stop].freeze

      # Tools that ONLY make sense for a subagent and must be hidden from a
      # primary/top-level agent. ask_parent escalates a question to the PARENT — a
      # top-level agent has no parent, so exposing it there would be a dead tool.
      # Subagents keep it; everyone else drops it. This is the single enforcement
      # point and is UNCHANGED by S1 (re-enabling nesting does not expose
      # ask_parent to top-level agents).
      SUBAGENT_ONLY_TOOLS = %w[ask_parent].freeze

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

        # ask_parent is subagent-only; a primary/top-level agent has no parent.
        # Nesting is otherwise allowed for everyone — the delegation tools stay.
        if subagent?
          tools
        else
          tools.reject { |t| SUBAGENT_ONLY_TOOLS.include?(t.name) }
        end
      end
    end
  end
end
