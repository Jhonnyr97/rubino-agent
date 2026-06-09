# frozen_string_literal: true

module Rubino
  module Tools
    # Singleton registry for all available tools.
    # Tools register themselves and can be looked up by name.
    class Registry
      @tools = {}

      class << self
        # Returns the singleton instance
        def instance
          self
        end

        # Registers a tool instance
        def register(tool)
          @tools[tool.name] = tool
        end

        # Finds a tool by name
        def find(name)
          @tools[name.to_s]
        end

        # Returns all registered tools
        def all
          @tools.values
        end

        # Returns only enabled tools based on configuration AND the active
        # mode (Modes.current). Plan mode pares the registry down to its
        # read-only whitelist so the model literally has no `edit`/`shell`/
        # `git` definition in the request — it can't even propose a mutating
        # tool call. Yolo and default leave everything through; their
        # difference is on the approval path, not the registry.
        def enabled_tools
          config = Rubino.configuration
          disabled = config.agent_disabled_toolsets

          @tools.values.reject do |tool|
            disabled.include?(tool.name) ||
              !tool_enabled_in_config?(tool, config) ||
              !Rubino::Modes.allows_tool?(tool.name) ||
              !aux_dependency_satisfied?(tool, config)
          end
        end

        # Returns tool definitions for LLM registration
        def tool_definitions
          enabled_tools.map(&:to_tool_definition)
        end

        # Clears all registered tools (useful for testing)
        def reset!
          @tools = {}
        end

        # Registers all default tools
        def register_defaults!
          register(Rubino::Tools::ReadTool.new)
          register(Rubino::Tools::SummarizeFileTool.new)
          register(Rubino::Tools::WriteTool.new)
          register(Rubino::Tools::EditTool.new)
          register(Rubino::Tools::MultiEditTool.new)
          register(Rubino::Tools::GrepTool.new)
          register(Rubino::Tools::GlobTool.new)
          register(Rubino::Tools::GitTool.new)
          register(Rubino::Tools::GitHubTool.new)
          register(Rubino::Tools::ShellTool.new)
          register(Rubino::Tools::ShellOutputTool.new)
          register(Rubino::Tools::ShellTailTool.new)
          register(Rubino::Tools::ShellInputTool.new)
          register(Rubino::Tools::ShellKillTool.new)
          register(Rubino::Tools::RubyTool.new)
          # Structured test-runner (issue #101): auto-detects rspec/minitest/
          # rake, prefers `bundle exec` (falls back when the bundle is broken),
          # and returns pass/fail counts + parsed failing examples instead of
          # the raw toolchain firehose the `shell` tool would dump.
          register(Rubino::Tools::TestTool.new)
          register(Rubino::Tools::PatchTool.new)
          register(Rubino::Tools::WebFetchTool.new)
          register(Rubino::Tools::WebSearchTool.new)
          register(Rubino::Tools::QuestionTool.new)
          register(Rubino::Tools::TodoTool.new)
          register(Rubino::Tools::MemoryTool.new)
          register(Rubino::Tools::SessionSearchTool.new)
          register(Rubino::Tools::AttachFileTool.new)
          register(Rubino::Tools::VisionTool.new)
          # Skills tool: loads a skill body (Level 2) and bundled files
          # (Level 3) on demand. Gated like any tool via `tools.skill`.
          register(Rubino::Skills::SkillTool.new)
          # Delegation tool: lets the model spawn an isolated subagent run.
          # Gated like any other tool (tools.task in config). Subagents now KEEP
          # it (scoped nesting, S1) — a subagent can spawn its own subagents,
          # bounded by the depth / fan-out / global caps in BackgroundTasks#reserve.
          register(Rubino::Tools::TaskTool.new)
          # Companion poll/stop tools for background subagents (the default
          # path of `task`). Mirror the shell_output/shell_kill trio. Gated by
          # the same tools.task key — disabling delegation disables these too.
          register(Rubino::Tools::TaskResultTool.new)
          register(Rubino::Tools::TaskStopTool.new)
          # ask_parent: the child->parent escalation tool. Registered globally
          # (gated by the same tools.task key), but Definition#resolved_tools
          # exposes it ONLY to subagents — a top-level agent has no parent to ask.
          register(Rubino::Tools::AskParentTool.new)
          # steer / probe (S2/S3): the MODEL-callable parent->child channels,
          # registered for ALL agents and AUTHORIZED by ownership at call time
          # (a node with no children just gets a "not your child" error). NOT on
          # any strip list — scoping happens inside the tool, not in the registry.
          register(Rubino::Tools::SteerTool.new)
          register(Rubino::Tools::ProbeTool.new)
        end

        private

        def tool_enabled_in_config?(tool, config)
          # Single source of truth: the tool declares its own `tools.<key>`
          # gate via #config_key (defaults to its name; webfetch/websearch
          # both return "web", filesystem returns "filesystem"). No more
          # string-munging the name here, which used to derive "webfetch"
          # and never query the shipped `tools.web` default — leaving
          # web tools enabled even when an operator set `tools.web: false`.
          value = config.dig("tools", tool.config_key)
          # If the key is absent from config, default to enabled (opt-out model).
          # Only disable when explicitly set to false.
          value.nil? ? true : value == true
        rescue StandardError
          true
        end

        # Hides tools whose runtime dependency isn't configured. Currently only
        # the `vision` tool: hide ONLY when no auxiliary is configured AND the
        # primary can't see — that's the one case where calling the tool would
        # error at runtime. In every other case keep it exposed, including when
        # the primary already supports vision natively: the model may prefer to
        # delegate to a better aux (e.g. primary "auto" routes to a mediocre
        # VLM but auxiliary is Gemini 2.5 Flash / MiniMax-M3). Letting the
        # model choose is cheap and sometimes the right call.
        def aux_dependency_satisfied?(tool, config)
          return true unless tool.name == "vision"

          aux_model = config.auxiliary_vision_config["model"].to_s
          !aux_model.empty? || config.model_supports_vision?
        end
      end
    end
  end
end
