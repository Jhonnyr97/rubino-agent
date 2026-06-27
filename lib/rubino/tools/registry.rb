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

        # The DISPLAY label for a registered tool name — the single resolution
        # point both the live tool card and the approval card route through, so
        # an MCP tool shows its `<bare> (mcp:<server>)` source while a built-in
        # renders unchanged. Detection is driven off the registered object being
        # an MCP wrapper (#mcp?), NEVER off the name's shape, so a built-in whose
        # name legitimately contains an underscore (read_attachment, shell_output)
        # is never mistaken for a `<server>_<tool>` MCP name. Falls back to the
        # bare name when the tool isn't registered (defensive — the model-facing
        # name is always a safe label).
        def display_label(name)
          tool = find(name)
          return name.to_s unless tool.respond_to?(:mcp?) && tool.mcp?

          tool.display_name
        end

        # Removes a tool by name (#182): stopping an MCP server must also drop
        # its MCPToolWrapper instances, or the model keeps seeing tools whose
        # client is gone and every call fails.
        def unregister(name)
          @tools.delete(name.to_s)
        end

        # Returns all registered tools
        def all
          @tools.values
        end

        # Returns only enabled tools based on configuration AND the active
        # mode (Modes.current). Plan mode pares the registry down to its
        # read-only whitelist so the model literally has no `edit`/`shell`
        # definition in the request — it can't even propose a mutating
        # tool call. Yolo and default leave everything through; their
        # difference is on the approval path, not the registry.
        def enabled_tools
          config = Rubino.configuration
          disabled = config.agent_disabled_toolsets

          @tools.values.reject do |tool|
            disabled.include?(tool.name) ||
              !tool_enabled_in_config?(tool, config) ||
              !Rubino::Modes.allows_tool?(tool.name) ||
              !aux_dependency_satisfied?(tool, config) ||
              situational_tool_hidden?(tool)
          end
        end

        # Returns tool definitions for LLM registration
        def tool_definitions
          enabled_tools.map(&:to_tool_definition)
        end

        # Clears all registered tools (useful for testing)
        def reset!
          @tools = {}
          # Drop the memoized web-capability probe (#411) so a fresh test run
          # re-evaluates it rather than inheriting a prior process's verdict.
          @web_backend_available = nil
        end

        # Registers all default tools
        def register_defaults!
          register(Rubino::Tools::ReadTool.new)
          register(Rubino::Tools::WriteTool.new)
          register(Rubino::Tools::EditTool.new)
          register(Rubino::Tools::MultiEditTool.new)
          register(Rubino::Tools::GrepTool.new)
          register(Rubino::Tools::GlobTool.new)
          register(Rubino::Tools::ShellTool.new)
          register(Rubino::Tools::ShellOutputTool.new)
          register(Rubino::Tools::ShellTailTool.new)
          register(Rubino::Tools::ShellInputTool.new)
          register(Rubino::Tools::ShellKillTool.new)
          register(Rubino::Tools::RubyTool.new)
          register(Rubino::Tools::PatchTool.new)
          register(Rubino::Tools::WebFetchTool.new)
          register(Rubino::Tools::WebSearchTool.new)
          register(Rubino::Tools::QuestionTool.new)
          register(Rubino::Tools::TodoTool.new)
          register(Rubino::Tools::MemoryTool.new)
          register(Rubino::Tools::SessionSearchTool.new)
          register(Rubino::Tools::AttachFileTool.new)
          # Gated, on-demand attachment reader (#6): converts a document to
          # Markdown IN-PROCESS (Rubino::Documents) and frames it as untrusted
          # data, so attachment bytes enter context only when the model asks.
          register(Rubino::Tools::ReadAttachmentTool.new)
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
          # steer / probe (S2/S3): the MODEL-callable parent->child channels,
          # registered for ALL agents and AUTHORIZED by ownership at call time
          # (a node with no children just gets a "not your child" error). NOT on
          # any strip list — scoping happens inside the tool, not in the registry.
          register(Rubino::Tools::SteerTool.new)
          register(Rubino::Tools::ProbeTool.new)
          # retrieve_output: the ONLY recovery path for compressed tool output.
          # Registered solely when tool_output_compression is enabled (the
          # default is OFF), so the shipped registry count is unchanged. When on,
          # the compression pointer carries an `id=…` and this tool reads the
          # spilled original back — deliberately NO cat-able path is printed, so
          # a small model can't shell-re-inflate the output compression shrank.
          register(Rubino::Tools::RetrieveOutputTool.new) if tool_output_compression_enabled_default?
        end

        # True when compression is enabled in the resolved config, used to gate
        # the retrieve_output tool's registration. Best-effort: any config error
        # falls back to OFF (matching the shipped default), so a broken config
        # never silently adds a tool that wouldn't otherwise be present.
        def tool_output_compression_enabled_default?
          Rubino.configuration.tool_output_compression_enabled?
        rescue StandardError
          false
        end

        # The delegate+poll toolset that MUST travel with `task` (spawn). The
        # `task` tool's own description tells the model it can "fetch the result
        # anytime with `task_result(<id>)` or stop it with `task_stop(<id>)`",
        # and `probe` is the read-only check-on-a-child companion. If we hid
        # these behind `any_subagent?` (the #313 token-saving gate) the model
        # would be PROMISED a tool that is absent from its function list — it
        # then concludes "I have no way to poll/verify my subagents" and the
        # delegate->poll->collect flow breaks. So we deliberately trade the
        # ~2k-token saving on these poll tools for correctness: they are exposed
        # whenever `task` itself is (i.e. only gated by `tools.task`, NOT by a
        # live child). The model needs the full delegate+poll toolset present to
        # plan delegation in the first place. (#313)
        TASK_POLL_TOOLS = %w[task_result task_stop probe].freeze

        # Tools that act ON a LIVE child and are NOT named in the `task`
        # description — they only make sense once a child SUBAGENT exists, so
        # they stay gated on `any_subagent?`. Before any task is spawned a
        # `steer` with no child just errors ("not your child"), so hiding it
        # costs no promised capability and keeps the common-turn schema lean.
        # `task` itself (spawn) stays always-on. (#313)
        TASK_DEPENDENT_TOOLS = %w[steer].freeze

        # Tools that ONLY make sense once a background SHELL exists this session —
        # the shell-management channels. Before any `shell run_in_background:true`
        # they have no handle to act on. `shell` itself stays always-on. (#313)
        SHELL_DEPENDENT_TOOLS = %w[shell_input shell_output shell_tail shell_kill].freeze

        private

        # Context-gates (#313) on SESSION-STABLE lifecycle signals, NOT per-turn
        # relevance — they flip at most once per session (when a subagent / a
        # background shell first appears), so the cached tool prefix that the
        # prompt-cache breakpoint (#311) protects stays byte-stable across the
        # common turn. Saves ~2k tokens on a normal file-edit turn that has
        # neither a child nor a background shell.
        #
        #   - task_result / task_stop / probe (TASK_POLL_TOOLS): NOT situationally
        #     hidden — they ride with `task` (gated only by `tools.task`) because
        #     the `task` description references task_result/task_stop and the
        #     model must see the whole delegate+poll toolset to plan delegation.
        #   - steer (TASK_DEPENDENT_TOOLS): acts on a LIVE child and isn't named
        #     in the task description, so it's exposed only once ≥1 child task
        #     exists in the BackgroundTasks registry.
        #   - shell_* management: exposed only once ≥1 background shell exists in
        #     the ShellRegistry.
        def situational_tool_hidden?(tool)
          case tool.name
          when *TASK_DEPENDENT_TOOLS
            !any_subagent?
          when *SHELL_DEPENDENT_TOOLS
            !any_background_shell?
          else
            false
          end
        end

        # True once at least one child task (in any state) exists this session.
        def any_subagent?
          BackgroundTasks.instance.list.any?
        rescue StandardError
          # Never let a registry probe failure hide a tool that should show — be
          # permissive (expose) on error, matching the opt-out posture elsewhere.
          true
        end

        # True once at least one background shell exists this session.
        def any_background_shell?
          ShellRegistry.instance.any?
        rescue StandardError
          true
        end

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
          value.nil? || value == true
        rescue StandardError
          true
        end

        # Hides tools whose runtime dependency isn't configured.
        #
        # - vision: hide ONLY when no auxiliary is configured AND the primary
        #   can't see — the one case where calling it would error at runtime. In
        #   every other case keep it exposed (the model may prefer a better aux).
        # - web (webfetch/websearch): now ships ON by default (#411), keyless via
        #   DuckDuckGo. Hide it only when the web backend is provably unreachable
        #   so an offline/air-gapped run DEGRADES gracefully (no web tool in the
        #   request) instead of the model calling a tool that can only error. The
        #   check is cached + best-effort: a reachable backend (an API key set,
        #   or DNS resolves) keeps the tools; only a clear "no network at all"
        #   removes them. On any uncertainty we KEEP the tools exposed (the tool
        #   itself already returns an error string rather than crashing a turn).
        def aux_dependency_satisfied?(tool, config)
          case tool.config_key
          when "vision"
            aux_model = config.auxiliary_vision_config["model"].to_s
            !aux_model.empty? || config.model_supports_vision?
          when "web"
            web_backend_available?
          else
            true
          end
        end

        # Best-effort capability check for the web tools (#411). A configured
        # search API (Tavily/SearXNG) is taken as available without a network
        # probe; otherwise we check that the DuckDuckGo host resolves. Result is
        # memoized for the process so it never adds per-turn latency, and any
        # error resolves to AVAILABLE (fail-open: keep the tool, let the call
        # surface a runtime error string rather than silently hiding web access).
        def web_backend_available?
          return @web_backend_available unless @web_backend_available.nil?

          @web_backend_available =
            if ENV["TAVILY_API_KEY"] || ENV["SEARXNG_URL"]
              true
            else
              require "resolv"
              !Resolv.getaddress("html.duckduckgo.com").nil?
            end
        rescue StandardError
          @web_backend_available = true
        end
      end
    end
  end
end
