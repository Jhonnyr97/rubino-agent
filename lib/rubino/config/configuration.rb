# frozen_string_literal: true

module Rubino
  module Config
    # Central configuration object providing typed accessors for all config sections.
    # Wraps the raw hash loaded by Config::Loader with convenient method access.
    class Configuration
      attr_reader :raw

      def initialize(raw: nil, home_path: nil)
        @home_path = home_path
        @raw = raw || load_from_file
      end

      # -- Model section --
      def model_default
        dig("model", "default")
      end

      def model_provider
        dig("model", "provider")
      end

      def model_context_length
        dig("model", "context_length")
      end

      def model_temperature
        dig("model", "temperature")
      end

      # -- Database section --
      # Resolves the sqlite path. The DEFAULT (sentinel) follows the resolved
      # home so RUBINO_HOME relocates the DB alongside config/.env/skills,
      # avoiding the split brain where config went to the isolated home but the
      # DB to the real ~/.rubino (issue #96). An EXPLICIT database.path in
      # config.yml wins and is expanded verbatim.
      def database_path
        path = dig("database", "path")
        if path == Defaults::DEFAULT_DATABASE_PATH
          File.join(resolved_home, "rubino.sqlite3")
        else
          File.expand_path(path)
        end
      end

      # -- Paths section --
      def paths_home
        dig("paths", "home")
      end

      # -- UI section --
      def ui_adapter
        dig("ui", "adapter")
      end

      def ui_verbose?
        dig("ui", "verbose") == true
      end

      # -- Display section --
      def display_streaming?
        dig("display", "streaming") == true
      end

      # -- Streaming section --
      def streaming_enabled?
        dig("streaming", "enabled") == true
      end

      # -- Agent section --
      def agent_max_turns
        dig("agent", "max_turns")
      end

      # Iteration/time caps fall back to the built-in defaults when the config
      # value is nil/missing (e.g. `config set agent.max_tool_iterations nil`,
      # whose writer coerces "nil" -> nil). A bare nil here would crash every
      # turn in IterationBudget's numeric comparisons (#139).
      def agent_max_tool_iterations
        dig("agent", "max_tool_iterations") || Defaults.dig("agent", "max_tool_iterations")
      end

      def agent_max_turn_seconds
        dig("agent", "max_turn_seconds") || Defaults.dig("agent", "max_turn_seconds")
      end

      def agent_api_max_retries
        dig("agent", "api_max_retries")
      end

      def agent_disabled_toolsets
        dig("agent", "disabled_toolsets") || []
      end

      # -- Tasks / nested-subagent caps --
      # Maximum nesting depth for the `task` delegation tree. depth 0 is a
      # human/top-level-spawned child; the cap bounds how deep a chain of
      # subagents-spawning-subagents may go. Default 2 ⇒ human→child→grandchild.
      # Falls back to the built-in default when missing/nil so the numeric caps
      # in BackgroundTask#reserve never crash on a bare nil.
      def tasks_max_depth
        dig("tasks", "max_depth") || Defaults.dig("tasks", "max_depth")
      end

      # Maximum number of LIVE direct children a single node (the human/top-level
      # or one subagent) may have at once. Default 3.
      def tasks_max_children_per_node
        dig("tasks", "max_children_per_node") || Defaults.dig("tasks", "max_children_per_node")
      end

      # Hard global ceiling on the total number of LIVE subagents across the whole
      # tree, so depth × fan-out cannot blow past the process's thread/cost budget.
      # Default 8.
      def tasks_max_concurrent_total
        dig("tasks", "max_concurrent_total") || Defaults.dig("tasks", "max_concurrent_total")
      end

      # Per-child budget for BILLED live probes (`probe(live:true)`). Over budget,
      # the model is steered to the FREE live:false snapshot. Free snapshots are
      # unlimited. Default 5.
      def tasks_max_live_probes_per_child
        dig("tasks", "max_live_probes_per_child") || Defaults.dig("tasks", "max_live_probes_per_child")
      end

      # Bound (seconds) a BLOCKING ask_parent waits for an answer before the child
      # self-heals and proceeds with its best judgement (S5a). Reuses the
      # approval-gate timeout convention — a sane upper bound, never "forever" —
      # so an abandoned ask never parks the child's thread indefinitely. Default 900.
      def tasks_ask_parent_timeout
        dig("tasks", "ask_parent_timeout") || Defaults.dig("tasks", "ask_parent_timeout")
      end

      # -- Prompts section --
      # The customer-facing preamble prepended to every assembled system
      # prompt. nil/empty disables the layer.
      def prompts_preamble
        value = dig("prompts", "preamble")
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def prompts_environment_enabled?
        # Default to on when the key is absent — env injection is the cheap
        # win we don't want a forgetful config.yml to disable accidentally.
        value = dig("prompts", "environment", "enabled")
        value.nil? || value == true
      end

      def prompts_environment_extra_utilities
        Array(dig("prompts", "environment", "extra_utilities")).map(&:to_s)
      end

      # Returns the override string for a given role name, or nil if the
      # built-in default prompt should be used.
      def prompts_override_for(role)
        value = dig("prompts", "overrides", role.to_s)
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end

      # -- Run lifecycle section --
      # Returns Float seconds (or nil to disable). EventsOperation uses this
      # to bound how long a "running" row can go without producing a new
      # event before the watchdog promotes it to failed.
      def run_idle_event_timeout
        raw = dig("run", "idle_event_timeout")
        return nil if raw.nil?

        raw.to_f
      end

      # -- Compression section --
      def compression_enabled?
        dig("compression", "enabled") == true
      end

      def compression_threshold
        dig("compression", "threshold")
      end

      def compression_gateway_threshold
        dig("compression", "gateway_threshold")
      end

      def compression_target_ratio
        dig("compression", "target_ratio")
      end

      def compression_protect_first_n
        dig("compression", "protect_first_n")
      end

      def compression_protect_last_n
        dig("compression", "protect_last_n")
      end

      def compression_max_summary_tokens
        dig("compression", "max_summary_tokens")
      end

      def compression_preserve_tool_pairs?
        dig("compression", "preserve_tool_pairs") == true
      end

      # -- Memory section --
      def memory_enabled?
        dig("memory", "enabled") == true
      end

      def memory_auto_extract?
        dig("memory", "auto_extract") == true
      end

      def memory_char_limit
        dig("memory", "memory_char_limit")
      end

      # Post-turn skill distillation. Defaults to true (skills feature on +
      # distill key absent ⇒ distill on), mirroring memory_auto_extract? as the
      # gate for an aux-spending background job. Turning skills off disables it
      # too, since there is no point distilling skills that won't be loaded.
      def skills_auto_distill?
        return false unless dig("skills", "enabled") != false

        value = dig("skills", "auto_distill")
        value.nil? || value == true
      end

      def memory_user_char_limit
        dig("memory", "user_char_limit")
      end

      # Ingest/store budget for the live memory set, decoupled from the
      # injection budget (`memory_char_limit`). `nil` => unbounded ingest.
      def memory_ingest_char_limit
        dig("memory", "ingest_char_limit")
      end

      # -- Jobs section --
      def jobs_mode
        dig("jobs", "mode")
      end

      def jobs_poll_interval
        dig("jobs", "poll_interval")
      end

      def jobs_max_attempts
        dig("jobs", "max_attempts")
      end

      # -- Tools section --
      def tool_enabled?(name)
        dig("tools", name.to_s) == true
      end

      def tool_output_max_bytes
        dig("tool_output", "max_bytes")
      end

      def tool_output_max_lines
        dig("tool_output", "max_lines")
      end

      # -- Security section --
      def approvals_mode
        dig("approvals", "mode")
      end

      # Seconds a run blocks on a human approval/clarification before the gate
      # gives up and AUTO-DENIES (freeing the worker thread). nil = wait
      # indefinitely (interruptible only by an explicit stop). Used by
      # ApprovalGate as its default await deadline so an abandoned approval
      # never parks a server worker for the whole window (W1).
      def approvals_wait_timeout
        raw = dig("approvals", "wait_timeout_seconds")
        return nil if raw.nil?

        raw.to_f
      end

      # When true, a `shell` tool call must always be confirmed in manual mode
      # even if the tool's own risk level wouldn't otherwise require it. Default
      # true (key absent = on) so shell-by-default stays gated behind a human.
      def require_confirmation_for_shell?
        dig("security", "require_confirmation_for_shell") != false
      end

      # Effective shell prompt policy: :confirm_all (every not-otherwise-allowed
      # shell command prompts — today's default) or :dangerous_only (safe shell
      # commands run unprompted; only DangerousPatterns matches prompt).
      #
      # Resolution / coercion (documented in defaults.rb):
      #   - if security.confirm_policy is set explicitly, it WINS (over the
      #     legacy alias);
      #   - otherwise it is DERIVED from require_confirmation_for_shell
      #     (true -> :confirm_all, false -> :dangerous_only),
      # so any deployment that only ever set the old alias keeps its behavior.
      # An unrecognized value falls back to the derived alias result.
      def confirm_policy
        raw = dig("security", "confirm_policy")
        return raw.to_sym if %w[confirm_all dangerous_only].include?(raw.to_s)

        require_confirmation_for_shell? ? :confirm_all : :dangerous_only
      end

      def security_command_allowlist
        dig("security", "command_allowlist") || []
      end

      # -- Providers section --
      def provider_config(name)
        dig("providers", name.to_s) || {}
      end

      # -- Auxiliary section --
      def auxiliary_compression_config
        dig("auxiliary", "compression") || {}
      end

      def auxiliary_vision_config
        dig("auxiliary", "vision") || {}
      end

      # Generic accessor for auxiliary task config blocks. Returns {} when
      # the task isn't defined, so callers can chain .dig safely.
      def auxiliary_config(task)
        dig("auxiliary", task.to_s) || {}
      end

      # Returns true when the primary model can ingest images directly. Honours
      # an explicit `model.supports_vision` override; otherwise falls back to
      # ContentBuilder's name-pattern heuristic. Used by VisionTool to decide
      # whether to expose itself (no point delegating if the primary can see).
      def model_supports_vision?
        raw = dig("model", "supports_vision")
        return raw == true unless raw.nil?

        LLM::ContentBuilder.supports_vision?(model_default.to_s)
      end

      # -- Generic access --
      def dig(*keys)
        @raw.dig(*keys)
      end

      def set(*keys, value)
        hash = @raw
        keys[0..-2].each do |key|
          hash[key] ||= {}
          hash = hash[key]
        end
        hash[keys.last] = value
      end

      def reload!
        @raw = load_from_file
      end

      private

      # The home this config is bound to: the explicit home_path passed at
      # construction, else the same resolver the Loader uses (RUBINO_HOME →
      # ~/.rubino). Read here (not at construction) so RUBINO_HOME just
      # needs to be set before database_path is first read.
      def resolved_home
        @home_path || Loader.default_home_path
      end

      def load_from_file
        loader = Loader.new(home_path: @home_path)
        loader.load
      end
    end
  end
end
