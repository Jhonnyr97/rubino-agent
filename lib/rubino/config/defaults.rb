# frozen_string_literal: true

module Rubino
  module Config
    # Default configuration values for the entire system.
    # These mirror the Rich config structure adapted for Ruby.
    module Defaults
      # Sentinel for the default database path. When config still carries this
      # value, Configuration#database_path resolves it against the resolved
      # home (RUBINO_HOME) instead of a literal ~/.rubino (issue #96).
      DEFAULT_DATABASE_PATH = "<RUBINO_HOME>/rubino.sqlite3"

      # Sentinel for the user-home commands directory. Resolved at read time
      # (Commands::Loader/Executor) against the resolved home (RUBINO_HOME)
      # instead of a literal ~/.rubino so commands in a custom home are
      # actually discovered (issue #38).
      HOME_COMMANDS_PATH = "<RUBINO_HOME>/commands"

      MODULE_DEFAULTS = {
        "model" => {
          "default" => "openai/gpt-4.1",
          "provider" => "auto",
          "context_length" => nil,
          "temperature" => 0.3,
          # Max output tokens for the anthropic-family path (anthropic_compatible
          # MiniMax, native anthropic, bedrock). ruby_llm defaults the Anthropic
          # max_tokens to 4096, which a reasoning model can exhaust on thinking
          # tokens alone → empty visible text. nil = use the adapter default
          # (16384). providers.<name>.max_tokens overrides per-backend.
          "max_tokens" => nil,
          # Thinking/reasoning token budget for the anthropic-family path. nil =
          # adapter default (8000, the reference "medium"). 0 disables thinking.
          # providers.<name>.thinking_budget overrides per-backend.
          "thinking_budget" => nil,
          # Visible-output headroom (tokens) reserved on top of the thinking
          # budget so the model can think AND answer. Mirrors the reference +4096.
          "max_tokens_text_headroom" => 4096,
          # nil = auto-detect from model_id via LLM::ContentBuilder.supports_vision?.
          # Set to true/false to override (e.g. when running behind a gateway that
          # hides the real upstream model name, like the gateway provider's `auto`).
          "supports_vision" => nil
        },
        "providers" => {
          "openai" => {
            "base_url" => nil,
            # Per-READ socket inactivity (resets on every streamed chunk), NOT a
            # total — this is the agent's first-token + inter-token idle bound,
            # same as the OpenAI/Anthropic SDK default. A silent socket fails
            # within this window and is retried pre-first-token. Raise it for a
            # large local Ollama that cold-loads for minutes before token #1.
            "request_timeout_seconds" => 600,
            "stale_timeout_seconds" => 300
          },
          "anthropic" => {
            "base_url" => nil,
            "request_timeout_seconds" => 600
          },
          "bedrock" => {
            "region" => "us-east-1",
            "request_timeout_seconds" => 600
          },
          "gemini" => {
            "request_timeout_seconds" => 600
          },
          # Opt-in provider for an OpenAI-compatible gateway. Point it at any
          # gateway that exposes an OpenAI-style /v1/* API: set base_url and
          # api_key and the agent routes everything here regardless of model id.
          # The gateway decides which upstream (OpenAI/Anthropic/…) and model
          # to call. Set model.provider: "gateway" to enable.
          "gateway" => {
            "openai_compatible" => true,
            "assume_model_exists" => true,
            "base_url" => nil,
            "request_timeout_seconds" => 600
          }
        },
        "auxiliary" => {
          "compression" => {
            "provider" => "main",
            "model" => "",
            "base_url" => nil,
            "timeout" => 120
          },
          "approval" => {
            "provider" => "main",
            "model" => "",
            "base_url" => nil,
            "timeout" => 30
          },
          # Multimodal aux. When set, the `vision` tool delegates here so a
          # text-only primary can still "see" an image. `provider: "main"`
          # reuses the primary's provider/base_url; otherwise both can be
          # overridden. Set `model: "auto-vision"` to let the gateway proxy
          # pick a vision model from the model catalog.
          "vision" => {
            "provider" => "main",
            "model" => "",
            "base_url" => nil,
            "timeout" => 120
          },
          # Document summarization. The `summarize_file` tool delegates here so
          # the raw bytes of a huge file are map-reduced in these aux calls and
          # never enter the main agent context (only the final summary returns).
          # `provider: "main"` reuses the primary's provider/model.
          "summarize" => {
            "provider" => "main",
            "model" => "",
            "base_url" => nil,
            "timeout" => 300
          }
        },
        "agent" => {
          "max_turns" => 90,
          "max_tool_iterations" => 8,
          "max_turn_seconds" => 120,
          # 5 retries with exponential backoff = 1+2+4+8+16 = 31s total wait.
          # Sized to absorb common provider blips (MiniMax intl in particular
          # has been observed returning "API server error - please try again"
          # for ~15-25 seconds before recovering) without timing out the user.
          "api_max_retries" => 5,
          # Hard ceiling (seconds) on a single full-jitter backoff draw between
          # retries: sleep = max(0.2, rand * min(2^(n-1), cap)). Caps worst-case
          # per-retry wait so a flapping backend can't stall a turn for minutes.
          "api_retry_backoff_cap_seconds" => 16,
          # Higher ceiling used ONLY for overload (529/503) and MiniMax "unknown
          # error" blips: those backends stay overloaded for tens of seconds, so
          # the 16s cap retries too eagerly back into a still-hot endpoint. 60s
          # lets the backoff ride out the overload window (the reference uses 120s).
          "api_retry_backoff_overload_cap_seconds" => 60,
          # In-turn retries for a 200-OK-but-EMPTY model response (no text, no
          # tool calls). After this many re-issues of the same turn the Loop
          # raises EmptyModelResponseError → run marked failed (never a silent
          # "completed but empty"). Mirrors the reference treating an empty/invalid
          # response as retryable-then-terminal.
          "empty_response_max_retries" => 2,
          # Provider/model fallback chain (Slice 7 — Agent::FallbackChain). An
          # ORDERED list of backends to rotate to when the primary keeps failing
          # (invalid/empty responses, rate-limit, overload, exhausted retries).
          # The primary is implicit (index 0); these are the fallbacks tried in
          # order. EMPTY by default → no fallback, behaviour byte-identical to a
          # single-provider setup. Each entry:
          #   { "provider" => "anthropic", "model" => "claude-...",
          #     "base_url" => nil, "api_key" => nil }
          # provider + model are required; base_url/api_key override the
          # providers.<name> config for that entry (custom endpoints). An entry
          # that resolves to the current provider/model/base_url is skipped
          # (dedup) so we never fall back to the backend that just failed.
          "fallback_models" => [],
          "disabled_toolsets" => [],
          "tool_use_enforcement" => "auto"
        },
        "run" => {
          # SSE watchdog: when a run is "running" but no new event has been
          # written for this many seconds, EventsOperation marks it failed and
          # emits a synthetic run.failed frame. Covers cases the executor's
          # rescue can't (model in infinite tool loop, provider stream hung,
          # OS-level thread death). Set to nil to disable.
          "idle_event_timeout" => 300
        },
        "database" => {
          # Sentinel: resolved at read time (Configuration#database_path) to
          # "<resolved home>/rubino.sqlite3" so the DB follows
          # RUBINO_HOME like config/.env/skills do. An explicit override
          # in config.yml replaces this and is used verbatim (issue #96).
          "path" => DEFAULT_DATABASE_PATH
        },
        "paths" => {
          "home" => "~/.rubino",
          "memory" => "~/.rubino/memories",
          "skills" => "~/.rubino/skills",
          "cron" => "~/.rubino/cron",
          "sessions" => "~/.rubino/sessions",
          "logs" => "~/.rubino/logs"
        },
        "ui" => {
          "adapter" => "cli",
          "theme" => "default",
          "verbose" => false
        },
        "display" => {
          "streaming" => true,
          # Tri-state reasoning render (display.reasoning): "hidden" suppresses
          # thinking entirely, "collapsed" buffers it and commits a one-liner cue
          # ("thought for Ns"), "full" renders the whole reasoning as a dim aside
          # above the answer. Deliberately NOT seeded here (#132): defaults
          # injecting it made the documented legacy display.show_reasoning
          # mapping (true→full, false→hidden, applied only when
          # display.reasoning is unset) unreachable for every config loaded
          # normally. Config::ReasoningPrefs supplies the "collapsed" default
          # when neither key is set.
          "language" => "en",
          "runtime_footer" => { "enabled" => false },
          "interim_assistant_messages" => false,
          # The dim status bar pinned UNDER the chat input (model id + context
          # saturation), refreshed at turn boundaries. Omitted automatically
          # off a TTY or on terminals narrower than 40 columns.
          "statusbar" => true,
          # Head lines of each tool's output shown in the transcript before a
          # dim "… +N lines (full output → context)" marker. DISPLAY-ONLY —
          # the model always receives the full (truncation-capped) output.
          # 0 disables the collapse (old full dump).
          "tool_output_preview_lines" => 3,
          # Cap on the chat input's visual rows: a long/multi-line prompt
          # wraps and grows the input downward up to this many rows, then
          # scrolls vertically (caret kept in view).
          "input_max_rows" => 8
        },
        "paste" => {
          # File-backed paste pipeline (UI::PasteStore). A paste with MORE
          # than collapse_lines lines collapses to a "[Pasted text #N +M
          # lines]" placeholder in the chat input, expanded to the full body
          # when the message is sent (the transcript echo keeps the
          # placeholder). A paste estimated above file_threshold_tokens
          # (chars/4) is written to <home>/sessions/<id>/paste_N.txt instead
          # and the sent message carries a read-tool pointer to it.
          "collapse_lines" => 5,
          "file_threshold_tokens" => 8000
        },
        "notifications" => {
          # Attention signals (UI::Notifier) for the moments the agent needs
          # human eyes: a long turn finishing, an approval prompt, a blocked
          # subagent. CLI-only; never emitted into a pipe.
          "enabled" => true,
          # Ring the terminal bell (BEL). On iTerm2 an OSC 9 escape is also
          # sent so it surfaces as a native macOS notification.
          "bell" => true,
          # Optional shell command spawned non-blocking per event with
          # RUBINO_EVENT (turn_finished|needs_approval|blocked) and
          # RUBINO_MESSAGE in its env — e.g. osascript / notify-send.
          "command" => nil,
          # A turn must run at least this many seconds before its completion
          # notifies; quick turns stay silent.
          "min_turn_seconds" => 10
        },
        "thinking" => {
          # Reasoning effort: off | low | medium | high. Mapped to an Anthropic
          # thinking-token budget (off→0, low→4000, medium→8000, high→16000) on
          # the anthropic-family path. "off" disables thinking. When SET it wins
          # over the model/provider thinking_budget chain; left nil (the default)
          # the budget falls through that chain, whose own default is 8000 — i.e.
          # the effective default effort is already "medium". /think reports
          # "medium" for the nil case.
          "effort" => nil
        },
        "streaming" => {
          "enabled" => true,
          "transport" => "off",
          "edit_interval" => 0.3,
          "buffer_threshold" => 40,
          "cursor" => " \u2589"
        },
        "context" => {
          "engine" => "compressor",
          "max_tokens" => nil
        },
        "compression" => {
          "enabled" => true,
          "threshold" => 0.50,
          "gateway_threshold" => 0.85,
          "target_ratio" => 0.20,
          "protect_first_n" => 3,
          "protect_last_n" => 20,
          "max_summary_tokens" => 12_000,
          "preserve_tool_pairs" => true
        },
        "memory" => {
          "enabled" => true,
          "backend" => "sqlite",
          "auto_extract" => true,
          "auto_save" => true,
          "user_profile_enabled" => true,
          "project_context_enabled" => true,
          "memory_char_limit" => 2200,
          "user_char_limit" => 1375,
          # Ingest/store cap for the live memory set, kept SEPARATE from the
          # injection budget above. `memory_char_limit` only bounds what gets
          # packed into the prompt at RETRIEVAL time; storing facts must not be
          # throttled by it or long multi-session conversations stall once the
          # injection budget fills. `nil` = unbounded ingest (the default).
          "ingest_char_limit" => nil,
          # Bounded retry budget for the aux extraction call on a transient
          # error (429 rate-limit / overloaded / 5xx). Under concurrent load the
          # aux call used to drop the fact on the first RateLimitError; now it
          # backs off and retries up to this many times (honouring Retry-After)
          # before giving up, and the per-session cursor re-feeds the turn next
          # time even then — so memory isn't lost to a transient rate limit.
          "extract_max_retries" => 3,
          # tiny-Zep SQLite backend tuning. `vector` enables best-effort
          # sqlite-vec/RubyLLM.embed KNN on top of the always-on FTS5 hybrid;
          # off by default so the stock install needs no extra deps. `graph`
          # is the graph-lite 1-hop entity/edge blend (on by default).
          "sqlite" => {
            "vector" => false,
            "graph" => true
          }
        },
        "jobs" => {
          "mode" => "inline",
          "poll_interval" => 2,
          "max_attempts" => 3,
          "retry_backoff_seconds" => 30
        },
        # Nested-subagent (the `task` delegation tool) caps. A subagent CAN now
        # spawn its own subagents; these three caps bound the tree so depth ×
        # fan-out cannot blow past the process's thread/cost budget. All three are
        # enforced in ONE place — Tools::BackgroundTasks#reserve — which refuses a
        # spawn (the tool then surfaces a clear at-capacity / max-depth message).
        "tasks" => {
          # Max nesting depth. depth 0 = a human/top-level-spawned child; the cap
          # bounds chains of subagents-spawning-subagents. 2 ⇒ human→child→grandchild
          # (no deeper).
          "max_depth" => 2,
          # Max LIVE direct children one node (human/top-level or a single
          # subagent) may have at once.
          "max_children_per_node" => 3,
          # Hard global ceiling on total LIVE subagents across the whole tree.
          "max_concurrent_total" => 8,
          # Per-child budget for BILLED live probes (`probe(live:true)`): how many
          # times an owner may run a one-shot model peek over a single child's
          # transcript. Over budget → the model is told to use the FREE
          # live:false snapshot instead. Free snapshots are unlimited.
          "max_live_probes_per_child" => 5,
          # Bound (seconds) a BLOCKING ask_parent waits before the child
          # self-heals and proceeds with its best judgement (S5a). Matches the
          # approvals wait-timeout default — never "forever".
          "ask_parent_timeout" => 900
        },
        "tools" => {
          # Sandbox write/edit/delete tools to workspace_root (terminal.cwd
          # or Dir.pwd). Set to false to let the model touch any path the
          # process can reach — only do this if you trust the model + the
          # approval flow alone.
          "workspace_strict" => true,
          "git" => true,
          # Default ON: the agent ships to run inside an isolated per-customer
          # VM where running shell commands is the whole point. The blast radius
          # is the VM, and security.require_confirmation_for_shell (default true)
          # still gates every command behind an approval prompt.
          "shell" => true,
          "ruby" => true,

          "web" => false,
          "memory" => true
        },
        "tool_output" => {
          "max_bytes" => 50_000,
          "max_lines" => 2000,
          "max_line_length" => 2000
        },
        "file_read" => {
          "max_chars" => 100_000
        },
        "terminal" => {
          "backend" => "local",
          "cwd" => nil,
          "file_sync_enabled" => false,
          "file_sync_max_mb" => 100
        },
        "approvals" => {
          "mode" => "manual",
          # Auto-allow provably READ-ONLY shell commands (ls, pwd, cat, grep,
          # git log, ...) without an approval prompt. The whole line must
          # parse as safe (Security::ReadonlyCommands): no redirection or
          # command/process substitution, every pipe/&&/; segment from the
          # read-only set, no mutating flags (find -exec/-delete, ...).
          # Anything ambiguous still prompts. The hardline floor and
          # permissions:deny always run first, so this never weakens them.
          "auto_allow_readonly" => true,
          # Extra command names (or leading-token prefixes, e.g. "docker ps")
          # merged into the built-in read-only set. The same parse validation
          # applies to every segment.
          "readonly_commands" => [],
          # How long (seconds) a run waits on a human approval/clarification
          # before giving up. On expiry the gate AUTO-DENIES (never approves)
          # and frees the worker thread — an abandoned approval (closed tab, no
          # answer) must not park a server worker indefinitely (W1). A sane
          # bound (15 min), not the old 24h that effectively never released.
          # Set to nil for a truly unbounded wait (interruptible only by an
          # explicit run stop; discouraged on shared servers). While a decision
          # is pending the SSE idle watchdog is suspended for that run
          # (EventsOperation), so the run is never reaped mid-wait.
          "wait_timeout_seconds" => 900
        },

        # SSRF guard for Run::AttachmentDownloader. Only URLs whose host is in
        # this list (case-insensitive) are fetched into the run workspace; the
        # downloader refuses everything else. ENV["ALLOWED_FILE_URL_HOSTS"]
        # (comma-separated) is merged in too, so a downstream consumer can keep
        # using its existing env knob. Loopback hosts (localhost, 127.0.0.1, ::1) are
        # ALWAYS allowed on top of this list, since an HTTP client co-located on the
        # same host produces loopback attachment URLs.
        # Empty list + empty env = only loopback is fetchable.
        "attachments" => {
          "allowed_hosts" => [],
          # Secure-by-default policy for the universal file-attachment handler
          # (Attachments::Classify / Preamble). Every default is on the secure
          # branch; explicit user config wins (Configuration merges over these).
          # Fail closed: oversize / unsafe / disallowed-kind => warn + skip.
          "policy" => {
            # Hard cap on accepted file size, enforced via lstat BEFORE reading.
            "max_file_bytes" => 26_214_400, # 25 MB
            # Inline budget for text files; over budget => head + read-rest note.
            "inline_text_budget_bytes" => 100_000, # ~25k tokens
            # Kinds the handler will process. Deny one by removing it.
            "allow_kinds" => %w[image text document archive binary],
            # Documents are hint-only by default (cost / injection blast radius);
            # the flag is reserved for a future in-process extract path.
            "auto_extract_documents" => false,
            # Routing an image to an EXTERNAL aux model is data egress; on by
            # default to preserve the existing aux-vision behaviour.
            "aux_vision_egress" => true,
            # Caps for any in-process archive listing (hint-only today, so
            # unused unless listing is enabled).
            "archive" => {
              "max_entries" => 2000,
              "max_uncompressed_bytes" => 268_435_456,
              "max_entry_ratio" => 100,
              "max_total_ratio" => 50,
              "max_nesting_depth" => 1
            }
          }
        },
        "security" => {
          # Prompt policy for shell commands not otherwise allowed/denied:
          #   confirm_all    (DEFAULT) every such command prompts for approval.
          #   dangerous_only (reference-faithful) safe commands run unprompted;
          #                  only DangerousPatterns matches prompt.
          # Intentionally NOT defaulted here: when the key is absent the
          # accessor derives it from require_confirmation_for_shell below
          # (true -> confirm_all, false -> dangerous_only). Setting the key
          # explicitly makes confirm_policy win over the legacy alias. The
          # hardline floor and permissions:deny always precede this regardless
          # of policy, so dangerous_only never weakens the non-bypassable floor.
          #
          #   "confirm_policy" => "confirm_all",
          #
          # Legacy alias for confirm_policy (see above). Kept working for any
          # existing readers. When true, every `shell` command goes through the
          # approval prompt regardless of the tool's own risk level. Default ON.
          "require_confirmation_for_shell" => true,
          # Ships ONLY provably read-only git verbs. Test/build runners
          # (`bundle exec rspec`, `rake`, `npm test`, ...) are deliberately NOT
          # shipped auto-approved: they load and execute arbitrary project code
          # by design (`rspec -r FILE`/`--require`, a Rakefile, a test helper),
          # so an allowlist entry for one is a default-config RCE past the
          # headless gate (SEC-R2-3). A code-loading runner is not safely
          # allowlistable; users who want one opt in explicitly.
          "command_allowlist" => [
            "git status",
            "git diff"
          ],

          "website_blocklist" => {
            "enabled" => false,
            "domains" => [],
            "shared_files" => []
          }
        },
        "privacy" => {
          "redact_pii" => false
        },
        "clarify" => {
          "timeout" => 120
        },
        "worktree" => {
          "enabled" => false
        },
        # System-prompt layering. Defaults ship the built-in role prompts
        # from lib/rubino/agent/prompts/*.txt. Customers customise via
        # config.yml:
        #   prompts.preamble — single block prepended after the role
        #     identity; the natural place for "You are running inside
        #     <product>" customer context.
        #   prompts.environment.enabled — when true (default) the assembler
        #     injects an [Environment] block with date/OS/cwd/git/runtimes
        #     and the list of CLI utilities found on PATH. Cached per
        #     process — re-probed every boot, not every turn.
        #   prompts.environment.extra_utilities — additional binaries to
        #     probe beyond EnvironmentInspector::DEFAULT_UTILITIES.
        #   prompts.overrides.<role> — full replacement of the built-in
        #     role prompt (escape hatch; prefer preamble for incremental
        #     tweaks).
        "prompts" => {
          "preamble" => nil,
          "environment" => {
            "enabled" => true,
            "extra_utilities" => []
          },
          "overrides" => {}
        },
        "quick_commands" => {},
        "mcp" => {
          "servers" => {}
        },
        "skills" => {
          "enabled" => true,
          # Post-turn skill distillation (Variant B). When true, a successful,
          # tool-heavy turn enqueues DistillSkillJob, which spends ONE auxiliary
          # model call to distil a reusable SKILL.md. Mirrors memory.auto_extract:
          # a separate toggle from `enabled` (which only controls whether skills
          # are loaded/usable) so a deployment — or a test that scripts a fixed
          # number of LLM turns — can keep skills usable while turning off the
          # extra background aux call.
          "auto_distill" => true,
          # Discover the skills shipped *inside the gem* (skills/<name>/SKILL.md),
          # so every install gets the built-in catalogue (e.g. ruby-expert) with
          # no copy step, on top of the user paths below. Built-ins are scanned
          # first, so a same-named user skill still overrides them. Set false to
          # run with only your own skills.
          "include_builtin" => true,
          "paths" => [
            ".rubino/skills",
            "~/.rubino/skills"
          ]
        },
        "commands" => {
          "paths" => [
            ".rubino/commands",
            HOME_COMMANDS_PATH
          ],
          # When false (default), !`shell` interpolation in command templates is
          # disabled. Set to true only in trusted environments where you explicitly
          # want command templates to execute shell commands.
          "shell_injection_enabled" => false
        },
        "permissions" => {},
        "formatters" => {},
        "agents" => {},
        "server" => {
          "port" => 4820,
          "auth" => false
        },
        "api" => {
          # Hard cap on JSON request bodies. Anything past this (whether
          # advertised by Content-Length or revealed mid-read) is rejected
          # with 413 before the parser allocates the full payload — keeps a
          # multi-GB POST from OOM-killing the process.
          "max_body_bytes" => 5 * 1024 * 1024,
          # Hard cap on multipart upload payload (POST /v1/files). Checked
          # against Content-Length first, then enforced mid-stream so a
          # truncated/missing Content-Length cannot saturate the disk.
          "max_upload_bytes" => 50 * 1024 * 1024,
          # Token-bucket rate limiter. Unauth bucket (per remote IP) protects
          # /v1/health and /v1/metrics from public floods; auth bucket (per
          # bearer token) caps authenticated callers. Storage is in-memory,
          # so multi-process deployments need a shared backend before this
          # gives meaningful protection across workers.
          "rate_limit_enabled" => true,
          "rate_limit_unauth_per_minute" => 60,
          "rate_limit_auth_per_minute" => 600
        }
      }.freeze

      class << self
        # Deep copy so a Configuration#set on a never-overridden nested section
        # (e.g. display.reasoning) mutates the per-config hash, NOT the shared
        # MODULE_DEFAULTS constant. A shallow .dup left nested section hashes
        # aliased to the constant, so the first /reasoning or /think write
        # poisoned the process-wide default.
        def to_hash
          deep_dup(MODULE_DEFAULTS)
        end

        def deep_dup(obj)
          case obj
          when Hash  then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
          when Array then obj.map { |v| deep_dup(v) }
          else            obj
          end
        end

        def to_yaml
          MODULE_DEFAULTS.to_yaml
        end

        def dig(*keys)
          MODULE_DEFAULTS.dig(*keys)
        end
      end
    end
  end
end
