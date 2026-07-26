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
        elsif path.to_s.start_with?(":memory:") || path.to_s == "file::memory:"
          # SQLite in-memory paths are sentinels, not filesystem paths —
          # expanding them would turn ":memory:" into "/cwd/:memory:".
          path
        else
          File.expand_path(path)
        end
      end

      # -- UI section --
      def ui_verbose?
        dig("ui", "verbose") == true
      end

      # -- Display section --
      def display_streaming?
        dig("display", "streaming") == true
      end

      # The status bar under the chat input (display.statusbar, default true).
      # Only an explicit false disables it.
      def display_statusbar?
        dig("display", "statusbar") != false
      end

      # Transcript preview budget for tool output
      # (display.tool_output_preview_lines): head lines shown before the
      # "… +N lines (full output → context)" marker. 0 = no collapse (full
      # dump). Display-only — the model-facing output is untouched.
      def display_tool_output_preview_lines
        value = dig("display", "tool_output_preview_lines")
        value.nil? ? 3 : value.to_i
      end

      # Cap on the chat input's visual rows (display.input_max_rows). Falls
      # back to the composer default for nil/zero/garbage so a bad value can
      # never collapse or unbound the input block.
      def display_input_max_rows
        value = dig("display", "input_max_rows").to_i
        value.positive? ? value : UI::BottomComposer::MAX_INPUT_ROWS
      end

      # Render the in-flight streamed block as formatted markdown in the live
      # region (display.live_markdown). Default true; only an explicit false
      # falls back to the legacy raw live tail.
      def display_live_markdown?
        dig("display", "live_markdown") != false
      end

      # Wrap each live-region frame in DEC-2026 synchronized output
      # (display.synchronized_output). Default true; only an explicit false
      # falls back to the legacy per-write frames.
      def display_synchronized_output?
        dig("display", "synchronized_output") != false
      end

      # Syntax-highlight committed code blocks (display.code_highlight). Default
      # true; only an explicit false falls back to plain (uncoloured) code.
      def display_code_highlight?
        dig("display", "code_highlight") != false
      end

      # -- Paste section (UI::PasteStore: the file-backed paste pipeline) --
      # A paste with MORE than this many lines collapses to a
      # "[Pasted text #N +M lines]" placeholder in the composer (expanded to
      # the full body at send). Falls back for nil/zero/garbage.
      def paste_collapse_lines
        value = dig("paste", "collapse_lines").to_i
        value.positive? ? value : UI::PasteStore::DEFAULT_COLLAPSE_LINES
      end

      # A paste with MORE than this many CHARACTERS also collapses to a
      # placeholder, even on a single line — a big one-line paste (a long token,
      # URL, minified JSON) would otherwise flood the composer because the
      # line-count trigger never fired. Falls back for nil/zero/garbage.
      def paste_collapse_chars
        value = dig("paste", "collapse_chars").to_i
        value.positive? ? value : UI::PasteStore::DEFAULT_COLLAPSE_CHARS
      end

      # A paste estimated above this many tokens (chars/4, the same rule
      # compaction uses) overflows to <home>/sessions/<id>/paste_N.txt and the
      # message carries a read-tool pointer instead of the content.
      def paste_file_threshold_tokens
        value = dig("paste", "file_threshold_tokens").to_i
        value.positive? ? value : UI::PasteStore::DEFAULT_THRESHOLD_TOKENS
      end

      # -- Chat section --
      # A bare `chat` auto-resumes the last session for the launch dir unless
      # explicitly disabled (see config/defaults.rb "chat" for the rationale).
      def chat_auto_resume?
        dig("chat", "auto_resume") != false
      end

      # -- Notifications section (UI::Notifier: attention bell + hook) --
      # enabled/bell are on unless explicitly false; command is nil unless a
      # non-empty string is set; min_turn_seconds falls back to the default.
      def notifications_enabled?
        dig("notifications", "enabled") != false
      end

      def notifications_bell?
        dig("notifications", "bell") != false
      end

      def notifications_command
        value = dig("notifications", "command").to_s
        value.empty? ? nil : value
      end

      def notifications_min_turn_seconds
        value = dig("notifications", "min_turn_seconds")
        (value.nil? ? Defaults.dig("notifications", "min_turn_seconds") : value).to_f
      end

      # -- Streaming section --
      def streaming_enabled?
        dig("streaming", "enabled") == true
      end

      # -- Doom-loop guard (#414) --
      # Default WARN-not-block (hard_stop false): a tripped detector surfaces a
      # warning to the model but does not deny the call.
      def doom_loop_hard_stop?
        dig("doom_loop", "hard_stop") == true
      end

      # Identical-consecutive-call threshold. Falls back to the detector default
      # when absent/garbage so a bad config value can't disable the guard.
      def doom_loop_threshold
        n = Integer(dig("doom_loop", "threshold"), exception: false)
        n && n >= 2 ? n : Security::DoomLoopDetector::DEFAULT_THRESHOLD
      end

      # -- Agent section --
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

      # At the iteration cap, prompt to continue/summarize/abort (#399). Defaults
      # to true; an explicit false forces the old always-summarize behaviour.
      # Independent of TTY — the headless guarantee lives in @ui.select returning
      # nil, not here.
      def agent_budget_extension_prompt?
        v = dig("agent", "budget_extension_prompt")
        v.nil? ? Defaults.dig("agent", "budget_extension_prompt") : v == true
      end

      # The "+N" one budget extension grants. nil/blank ⇒ max_tool_iterations,
      # so an extension doubles the per-turn runway (the Cline/Roo "reset the
      # counter, keep context" amount). Coerced to a positive Integer; a bad
      # value falls back to the iteration cap.
      def agent_budget_extension_step
        raw = dig("agent", "budget_extension_step")
        n = Integer(raw, exception: false)
        n&.positive? ? n : agent_max_tool_iterations
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

      # Bound (seconds) an interactive `question`/clarify waits for the human to
      # answer before it EXPIRES CLEANLY and the agent proceeds with its best
      # judgement (#552). Mirrors the Hermes clarify_timeout convention — a
      # generous upper bound (default 600s = 10 min, well above
      # human reading/deliberation time), never the 30s stale-chunk window and
      # never "forever". An abandoned clarify self-heals into the NO_ANSWER
      # outcome instead of hanging the run or being killed by the stale watchdog.
      def clarify_timeout
        dig("clarify", "timeout") || Defaults.dig("clarify", "timeout")
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

      # Throttle interval (in turns) for memory.auto_extract (#412). Returns a
      # positive Integer; nil/<=1 (or absent) ⇒ 1 = every turn. The lifecycle
      # only enqueues the background review fork when turns-since-last >= this.
      def memory_auto_extract_interval
        positive_interval(dig("memory", "auto_extract_interval"))
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

      # Throttle interval (in turns) for skills.auto_distill (#414). Mirrors
      # memory_auto_extract_interval. nil/<=1 ⇒ every eligible turn.
      def skills_auto_distill_interval
        positive_interval(dig("skills", "auto_distill_interval"))
      end

      # -- Tools section --
      def tool_enabled?(name)
        dig("tools", name.to_s) == true
      end

      # Hard RAM ceiling for the shell capture seam (#539). Defaults via the
      # defaults hash; coerced to a sane positive floor so a misconfig can't
      # disable the cap and re-open the unbounded-producer OOM.
      def tool_output_capture_max_bytes
        value = dig("tool_output", "capture_max_bytes").to_i
        value.positive? ? value : 2_000_000
      end

      # Deterministic, reversible compression of tool-read results (whole-file
      # Ruby reads → skeleton). OFF by default: when false the read tool is
      # byte-for-byte unchanged. See Compression::Compressor.
      def tool_output_compression_enabled?
        dig("tool_output_compression", "enabled") == true
      end

      def tool_output_compression_code
        dig("tool_output_compression", "code") || {}
      end

      # Source languages the code skeletoner is enabled for (e.g. ["ruby"]).
      # A whole-file read whose language isn't in this list passes through
      # verbatim. Ruby uses the built-in Prism parser; later languages need
      # their own parser registered before being added here.
      def tool_output_compression_code_languages
        tool_output_compression_code["languages"] || []
      end

      # DIFF compression config. Like `code`, it has NO own `enabled` sub-flag:
      # it is active whenever the master `tool_output_compression.enabled` is on.
      # The DiffCompressor's saving guard (min_lines + min_saving) is the real
      # gate — a small/tight diff passes through byte-identical on its own.
      def tool_output_compression_diff
        dig("tool_output_compression", "diff") || {}
      end

      # LOG/command-output compression config. Independently gated from `code`
      # via its own `enabled` flag, so we can flip the high-ROI log channel on
      # without touching the code-skeleton channel.
      def tool_output_compression_logs
        dig("tool_output_compression", "logs") || {}
      end

      # JSON compression config. Like `code`/`diff`, it has NO own `enabled`
      # sub-flag: it is active whenever the master `tool_output_compression.enabled`
      # is on. The JsonCompressor's saving + size guards are the real gate — small
      # JSON the model wants verbatim passes through byte-identical on its own.
      def tool_output_compression_json
        dig("tool_output_compression", "json") || {}
      end

      def tool_output_compression_logs_enabled?
        tool_output_compression_logs["enabled"] == true
      end

      # -- Security section --
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

      # Auto-allow provably read-only shell commands (ls, cat, grep, git log,
      # ...) without an approval prompt. Default ON (key absent = on); the
      # hardline floor and permissions:deny still precede it.
      def auto_allow_readonly?
        dig("approvals", "auto_allow_readonly") != false
      end

      # Extra command names / leading-token prefixes merged into the built-in
      # read-only set (Security::ReadonlyCommands::SAFE_COMMANDS).
      def approvals_readonly_commands
        dig("approvals", "readonly_commands") || []
      end

      # Effective shell prompt policy and SOLE source of truth (item 7): the
      # legacy security.require_confirmation_for_shell alias was REMOVED — no
      # back-compat mapping. :dangerous_only (DEFAULT — safe shell commands run
      # unprompted; only DangerousPatterns matches prompt) or :confirm_all (every
      # not-otherwise-allowed shell command prompts). An unset or unrecognized
      # value falls back to the seeded :dangerous_only default. A config that
      # still carries the removed key is NOT silently honored — Validator.warnings
      # flags it at load + in `rubino doctor`.
      def confirm_policy
        raw = dig("security", "confirm_policy")
        return raw.to_sym if %w[confirm_all dangerous_only].include?(raw.to_s)

        :dangerous_only
      end

      # The pre-approved command allowlist, always returned as an Array.
      #
      # YAML lets a user write `command_allowlist: git status` (a scalar) where
      # a sequence was meant. The matcher (CommandAllowlist#allowlist_token_lists)
      # calls #filter_map on this value; a bare String would raise an unhandled
      # NoMethodError out of the approval path (a crash, not the clean
      # fail-closed contract — CFG-R3-1). Coerce a scalar to a single-entry
      # array and drop any nil so the matcher always receives a well-formed list.
      def security_command_allowlist
        raw = dig("security", "command_allowlist")
        case raw
        when Array then raw
        when nil then []
        else [raw]
        end
      end

      # -- Providers section --
      def provider_config(name)
        dig("providers", name.to_s) || {}
      end

      # -- Auxiliary section --
      def auxiliary_vision_config
        dig("auxiliary", "vision") || {}
      end

      # Generic accessor for auxiliary task config blocks. Returns {} when
      # the task isn't defined, so callers can chain .dig safely.
      def auxiliary_config(task)
        dig("auxiliary", task.to_s) || {}
      end

      # True when the auxiliary +task+ resolves to the SAME server ENDPOINT as the
      # main model — i.e. its LLM calls land on the main model server's KV slot.
      # Slot-sharing is about the endpoint (provider + base_url), NOT the model: a
      # different model on the SAME server still shares the single slot. At the
      # defaults (auxiliary.<task>.provider:"main", empty base_url) this is true.
      #
      # It matters for local single-slot servers: an aux call sharing the slot
      # OVERWRITES the live conversation's KV-cache prefix, so the next user turn
      # re-prefills the whole context (the "freeze after N turns"). The post-turn
      # extraction/distill gates use this to stay OFF the interactive slot,
      # mirroring how Hermes/Claude Code keep automatic memory work off the live
      # conversation (extract at session end instead). A DISTINCT aux endpoint
      # (its own server/slot) does not evict, so inter-turn extraction stays on.
      def auxiliary_on_main_endpoint?(task)
        cfg = auxiliary_config(task)
        provider = cfg["provider"].to_s.strip
        aux_provider = provider.empty? || provider == "main" ? dig("model", "provider").to_s : provider

        aux_base = cfg["base_url"].to_s.strip
        aux_base = provider_config(aux_provider)["base_url"].to_s.strip if aux_base.empty?
        main_base = provider_config(dig("model", "provider").to_s)["base_url"].to_s.strip

        aux_provider == dig("model", "provider").to_s && aux_base == main_base
      end

      # Returns true when the primary model can ingest images directly. Honours
      # an explicit `model.supports_vision` override; otherwise falls back to
      # ContentBuilder's name-pattern heuristic. Used by VisionTool to decide
      # whether to expose itself (no point delegating if the primary can see).
      def model_supports_vision?
        raw = dig("model", "supports_vision")
        return raw == true unless raw.nil?

        LLM::ContentBuilder.supports_vision?(dig("model", "default").to_s)
      end

      # -- API section --
      # Whether the HTTP API server may bind to a non-loopback address. SAFE BY
      # DEFAULT (#577): false REFUSES a routable bind (the API runs shell tools);
      # set true to deliberately publish the listener (use TLS + a strong key).
      def api_allow_public_bind?
        dig("api", "allow_public_bind") == true
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

      # Coerce a turn-interval setting to a positive Integer >= 1. Absent / nil /
      # non-positive / garbage ⇒ 1 (every turn), so a throttle gate never divides
      # by zero or silently disables the gated work.
      def positive_interval(raw)
        n = Integer(raw, exception: false)
        n && n >= 1 ? n : 1
      end

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
