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
          # Public-gem default is OpenAI gpt-4.1 (maintainer directive): it is
          # the most broadly available provider and needs no special provider
          # block to route — just OPENAI_API_KEY — so a defaults-only config is
          # coherent and the first turn works. MiniMax stays an AVAILABLE wizard
          # choice but is NOT the seeded/recommended default. The onboarding
          # wizard's recommended (first) entry mirrors this exact default.
          # provider "auto" derives the concrete provider from the model id
          # (openai/* → openai); the wizard/auto-detect write an explicit
          # provider when the user/env picks a non-OpenAI backend.
          "default" => "openai/gpt-4.1",
          "provider" => "auto",
          "context_length" => nil,
          # nil = inherit the provider default (Hermes injects no temperature).
          # 0.3 used to be hardcoded but is inert under thinking-on (forced to 1)
          # and only surfaced when thinking was disabled (#414).
          "temperature" => nil,
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
            "stale_timeout_seconds" => 300,
            # Free-form hash merged verbatim into the OpenAI-style
            # /v1/chat/completions request body (top level). Only honored on the
            # OpenAI-compatible request path; ignored on the anthropic-family
            # path. Empty ⇒ byte-identical request to before. See the gateway
            # block below and docs/configuration.md for the canonical example.
            "extra_body" => {}
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
            "request_timeout_seconds" => 600,
            # Free-form hash merged verbatim into the OpenAI-style
            # /v1/chat/completions request body (deep-merged at the top level via
            # ruby_llm's with_params). Use it to pass provider-specific knobs the
            # adapter does not model natively. The canonical case is suppressing
            # chain-of-thought leakage on oMLX / Qwen-style backends that emit
            # <think> text instead of native tool_calls unless the request
            # carries:
            #
            #   providers:
            #     gateway:
            #       extra_body:
            #         chat_template_kwargs:
            #           enable_thinking: false
            #
            # Only applied on the OpenAI-compatible path; never on the
            # anthropic-family path, and never touches the thinking-budget logic.
            # Empty ⇒ byte-identical request to before.
            "extra_body" => {}
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
          # Summarization aux task. Used by skill distillation
          # (jobs/handlers/distill_skill_job.rb, task: "summarize") to condense
          # captured transcripts into a reusable skill; routed through this aux
          # backend so it never blocks the live turn.
          # `provider: "main"` reuses the primary's provider/model.
          "summarize" => {
            "provider" => "main",
            "model" => "",
            "base_url" => nil,
            "timeout" => 300
          },
          # Session titling. Deterministic by default (#103): a session is
          # titled by Session::Repository.derive_title with NO model call. When
          # this block names a CONCRETE aux backend distinct from the primary
          # (a non-"main" provider OR a non-empty model), the first user message
          # is instead summarized into a short title via the aux LLM (#45),
          # falling back to the deterministic title on any error/empty result.
          # At the defaults below (provider:"main", model:"") nothing is
          # "configured", so titling stays deterministic.
          "title" => {
            "provider" => "main",
            "model" => "",
            "base_url" => nil,
            "timeout" => 30
          },
          # Embeddings aux endpoint (opt-in, no default — must be explicitly
          # configured in config.yml when `memory.sqlite.vector: true`).
          # Point this at a local embedding model (e.g. an oMLX/ds4 embeddings
          # endpoint) to get semantic recall with NO paid API — local-first,
          # off by default. See docs/memory.md.
        },
        "agent" => {
          # OUTER rail on tool iterations, enforced in IterationBudget alongside
          # max_tool_iterations (#414): the budget caps at min(max_tool_iterations,
          # max_turns). Previously DEAD config (assigned, never read); now wired as
          # a real ceiling. `--max-turns N` overrides max_tool_iterations directly.
          "max_turns" => 90,
          # Per-turn model↔tool round-trip cap. Aligned to the Hermes reference
          # (90), which is also the outer `max_turns` rail — so a real multi-step
          # task runs to completion instead of stopping to ask after a couple
          # dozen tool calls (the prior 25 was a deliberate Cursor-aligned cap,
          # #414, but read as too eager for genuine multi-file work). The
          # budget-extension prompt + the runaway backstops below still bound a
          # truly looping turn. `--max-turns N` overrides this directly.
          "max_tool_iterations" => 90,
          # At the iteration cap, in INTERACTIVE mode, prompt the user to
          # continue/summarize/abort instead of silently force-summarizing (#399).
          # false forces the old always-summarize behaviour; headless/non-TTY
          # runs ALWAYS force-summarize regardless of this flag (no human to ask).
          "budget_extension_prompt" => true,
          # The "+N" granted by one budget extension at the cap. nil ⇒ use
          # max_tool_iterations (so one extension doubles the runway). Capped by
          # the outer max_turns rail, which extensions do NOT raise — repeated
          # extensions can never bypass the iteration/turn ceiling.
          "budget_extension_step" => nil,
          # Pure SAFETY-NET wall clock on a single turn, NOT a working-time cap
          # (#408). Hermes' IterationBudget has no clock at all; the old 120s
          # KILLED slow-but-legitimate test/build turns mid-work (and was the
          # root that made the #403 budget-extension loop possible). Even the
          # raised 600s still guillotines legitimate work: a genuine multi-file
          # "compare docs vs code" audit on a LOCAL model runs ~40 tool calls in
          # ~13 min, blowing 600s and force-summarizing the turn into a confused
          # non-answer — the exact failure #408 warned about. So the wall clock
          # is DISABLED by default (nil): the tool-iteration budget
          # (max_tool_iterations, 90) is the real runaway guard, and individual
          # hung tools are bounded by their own per-tool timeouts. Hermes parity.
          # Set a positive number to re-arm the clock as an explicit backstop.
          "max_turn_seconds" => nil,
          # 5 retries with exponential backoff = 1+2+4+8+16 = 31s total wait.
          # Sized to absorb common provider blips (MiniMax intl in particular
          # has been observed returning "API server error - please try again"
          # for ~15-25 seconds before recovering) without timing out the user.
          "api_max_retries" => 5,
          # Hard ceiling (seconds) on a single full-jitter backoff draw between
          # retries on the ERROR path: delay = min(base*2^(n-1), cap) + jitter.
          # Caps worst-case per-retry wait so a flapping backend can't stall a
          # turn on one sleep. 16 keeps the worst single wait to ~24s (16 +
          # 0.5*16 jitter) instead of the 60s ERROR_PATH ceiling. (Previously
          # declared but NEVER read — the error path hardcoded the 60s cap.)
          "api_retry_backoff_cap_seconds" => 16,
          # Hard TOTAL wall-time budget (seconds) across all error-path retries
          # for one model call. A permanently-unreachable host (resolves but the
          # port is dead → retryable connection timeout) used to burn ~75-110s
          # across 5 retries before giving up. This is a Codex-style "total
          # elapsed" cap: keep retrying genuinely-transient errors, but once the
          # cumulative backoff already spent PLUS the next planned wait would
          # cross this budget, fail fast with a clear "gave up after ~Ns" message
          # instead of stalling the user. Does NOT shorten legitimate recovery
          # inside the window. nil ⇒ no total cap (count-based only).
          "api_retry_total_timeout_seconds" => 30,
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
          "input_max_rows" => 8,
          # Render the still-streaming (in-flight) block as FORMATTED markdown in
          # the live region — bold/headings/lists/code style as they arrive
          # (incomplete syntax repaired by MarkdownRepair) — instead of the raw
          # rolling-tail text that only snaps to styled when the block commits.
          # On by default (the Claude-like live feel, verified in a real
          # terminal); false ⇒ the legacy raw live tail (exact prior behaviour).
          "live_markdown" => true,
          # Wrap each live-region frame in DEC-2026 synchronized output
          # (BSU/ESU) so a supporting terminal swaps the frame atomically — no
          # flicker/tearing on multi-step repaints. Unsupported terminals ignore
          # the private mode, so it degrades cleanly; emitted only to a real TTY.
          # false ⇒ the legacy per-write frames.
          "synchronized_output" => true,
          # Syntax-highlight fenced code blocks by language (Rouge) in the
          # COMMITTED render — the live tail stays unstyled, so highlighting
          # never blocks the stream (code shows instantly, colours a beat later
          # on commit). Unknown languages and any failure fall back to the plain
          # code body. On by default; false ⇒ plain (uncoloured) code blocks.
          "code_highlight" => true
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
          # A paste longer than this many CHARS also collapses to the chip, even
          # on a single line — a big one-line paste (long URL/token/minified
          # JSON) would otherwise flood the composer.
          "collapse_chars" => 400,
          "file_threshold_tokens" => 8000
        },
        "notifications" => {
          # Attention signals (UI::Notifier) for the moments the agent needs
          # human eyes: a long turn finishing, or an approval prompt. CLI-only;
          # never emitted into a pipe.
          "enabled" => true,
          # Ring the terminal bell (BEL). On iTerm2 an OSC 9 escape is also
          # sent so it surfaces as a native macOS notification.
          "bell" => true,
          # Optional shell command spawned non-blocking per event with
          # RUBINO_EVENT (turn_finished|needs_approval) and
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
          "buffer_threshold" => 40
        },
        "context" => {
          "engine" => "compressor",
          "max_tokens" => nil
        },
        "compression" => {
          "enabled" => true,
          "threshold" => 0.50,
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
          # Throttle the background aux-LLM memory extraction to ~every N turns
          # instead of EVERY turn (#412), mirroring Hermes' nudge_interval (10):
          # extraction enqueues only when turns-since-last-extract >= this. 10x
          # fewer aux calls + far less of the conversation shipped to the
          # extractor. nil/<=1 = every turn (old behaviour). The extract is also
          # ALWAYS backgrounded off the interactive critical path (never drained
          # inline on the live CLI turn).
          "auto_extract_interval" => 10,
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
          # SQLite memory backend tuning. `vector` enables best-effort
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
          "retry_backoff_seconds" => 30,
          # How long a CLAIMED (queued -> running) row may stay `running` before
          # it's presumed abandoned and reclaimed (#76). A worker that claims a
          # row and then dies / is quit / hangs leaves it `running` with
          # locked_by set; nothing in the queue scan re-picks a `running` row, so
          # pre-fix it sat forever (0 attempts, queue grew across sessions). The
          # next drain reclaims any row whose lock is older than this lease,
          # bumping attempts so a genuinely stuck job still goes terminal at
          # max_attempts rather than re-running forever. Generous (15 min) so a
          # legitimately slow aux-LLM job is never yanked out from under itself.
          "lock_lease_seconds" => 900
        },
        # Session/spill cleanup (opportunistic at startup, not a cron job).
        # Deletes ENDED sessions older than period_days + their spill files.
        # Throttled to at most once per 24h.
        #
        #   period_days (default 30)       — retention window in days.
        #     nil / false / "off" / 0 / negative → OFF (cleanup disabled).
        #     Do NOT overload 0 as "retain forever" — use nil/false/"off".
        #   min_retention_days (default 1) — floor: newer sessions are
        #     UNTOUCHABLE regardless of status. Prevents the Claude Code
        #     0-day wipe-the-workspace bug.
        "cleanup" => {
          "period_days" => 30,
          "min_retention_days" => 1
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
          "max_live_probes_per_child" => 5
        },
        "tools" => {
          # Recover tool calls a model LEAKS AS TEXT (tool-call markup in the
          # assistant content instead of the structured field) — MiniMax's
          # anthropic-compatible endpoint does this — by parsing the markup back
          # into real tool calls the agent executes, and stripping it from saved
          # content so it can't poison history. Covers the format families that
          # account for ~80% of open models (Hermes/Qwen JSON, MiniMax/Qwen3-Coder
          # XML, Mistral arrays). Inert when native tool calls exist or no markup
          # is present (no false positives). Set false to disable the recovery.
          "recover_text_tool_calls" => true,
          # Sandbox write/edit/delete tools to workspace_root (terminal.cwd
          # or Dir.pwd). Set to false to let the model touch any path the
          # process can reach — only do this if you trust the model + the
          # approval flow alone.
          "workspace_strict" => true,
          # Default ON: the agent ships to run inside an isolated per-customer
          # VM where running shell commands is the whole point. The blast radius
          # is the VM, and security.confirm_policy (default dangerous_only) still
          # routes any DangerousPattern command through an approval prompt while
          # safe commands run unprompted (set confirm_policy: confirm_all to gate
          # every command).
          "shell" => true,
          "ruby" => true,

          # OS-level write jail around the shell tool's single Process.spawn
          # (#290/#544). The per-command allowlist is a UX guard-rail, not a
          # boundary; this is the real floor (Security::Sandbox).
          #   mode: off | read-only | workspace-write   (default workspace-write)
          #     off            — no OS confinement (byte-identical to pre-sandbox)
          #     read-only      — workspace is read-only; writes only to temp
          #     workspace-write— writes confined to workspace + temp (NOT
          #                      ~/.rubino: it holds the sandbox trust anchors)
          #   network: allow (slice 1; deny/proxy are slice 3+)
          #   extra_writable: extra absolute paths added to the write jail
          #   require: false — fail-OPEN when no mechanism exists (default).
          #     Set true to FAIL-CLOSED: shell (foreground AND background)
          #     REFUSES to run when the sandbox is unavailable, for the
          #     paranoid / multi-tenant-host operator (slice 2 Part B).
          #   escalation: off | protect-home | full   (default protect-home)
          #     Governs the disable_sandbox escape hatch — re-running a shell
          #     command OUTSIDE the jail after EXPLICIT approval when a write-jail
          #     denial blocked it (§B).
          #     off          — no hatch; the flag is ignored and a jailed write
          #                    hard-fails (Claude allowUnsandboxedCommands:false).
          #     protect-home — DEFAULT. An approved escalation runs UNCONFINED
          #                    on every platform — the approval prompt (step 4b)
          #                    is the only boundary. ~/.rubino is NOT OS-blocked
          #                    during escalation; the human decides.
          #     full         — Codex-style: an approved escalation is fully
          #                    unconfined; the human approval is the only boundary.
          # Always-on when a mechanism exists, INCLUDING under --yolo (--yolo
          # skips approval prompts, not the OS write-jail). Fails OPEN with a
          # one-time loud banner where no mechanism is available (old kernel,
          # non-mac/linux); set mode: off to silence it deliberately.
          # devices: OS device access the write-jail grants to sandboxed shell
          # commands (macOS/Seatbelt only; Linux/Landlock ignores it). See below.
          "sandbox" => {
            "mode" => "workspace-write",
            "network" => "allow",
            "extra_writable" => [],
            "require" => false,
            "escalation" => "protect-home",
            "devices" => {
              # GPU/Metal (MLX, MPS) device access, ALWAYS-ON by default: the
              # named IOKit user-clients are appended to the Seatbelt profile so
              # a sandboxed command can reach the GPU. The write-jail stays ON —
              # this grants no filesystem write nor extra network, so it is not a
              # boundary worth a per-command prompt (unlike disable_sandbox, the
              # write-jail escape hatch). No shell param, no approval — just the
              # global knob below. macOS/Seatbelt only (Linux/Landlock has no
              # device concept → GPU already works there, this map is ignored).
              #   mode: allow (default) | deny
              #     allow — user-clients added to every sandboxed spawn
              #     deny  — never added (lock-down / multi-tenant hosts); a
              #             GPU command then fails with "No Metal device"
              #   iokit_user_clients: the user-client classes appended to the
              #     profile (sanitized to [A-Za-z0-9_]). ADD A NEW DEVICE by
              #     adding an entry here — no code change.
              "gpu" => {
                "mode" => "allow",
                "iokit_user_clients" => [
                  "AGXDeviceUserClient",
                  "IOGPUDeviceUserClient",
                  "IOSurfaceRootUserClient",
                  "IOSurfaceSendRight",
                  "AppleGraphicsDeviceControlClient"
                ]
              }
            }
          },

          # Default ON, matching Hermes (web tools ship in the default toolset,
          # keyless via the DuckDuckGo backend) (#411). Gated at runtime on
          # backend reachability in Registry#web_backend_available? so an
          # unreachable network DEGRADES gracefully (the tool is hidden / its
          # call returns an error string) rather than crashing a turn.
          "web" => true,
          "memory" => true,

          # Headless-browser fallback for JS-rendered pages (SPAs) in the
          # webfetch tool. Only ever engages when the OPTIONAL `ferrum` gem AND a
          # Chrome/Chromium binary are present — both installed on demand, never
          # bundled (see install.sh). With ferrum absent this whole block is
          # inert and every fetch uses the static Net::HTTP path.
          #   "auto"   — render only when the static response SCORES as a
          #              client-rendered shell (empty app-shell root div, hydration
          #              state, thin extracted text — a weighted multi-signal
          #              classifier, not one threshold). Cheap: no browser on
          #              normal server-rendered pages.
          #   "off"    — never render.
          #   "always" — render every page (slower; for debugging).
          "webfetch" => {
            "js_rendering" => "auto",

            # Let webfetch reach loopback/LAN addresses (localhost dev servers,
            # internal services) — rubino is a LOCAL dev agent, so blocking its
            # own localhost is user-hostile. The cloud-metadata floor
            # (169.254.169.254 etc.) stays blocked regardless. Set to false to
            # restore strict public-only fetching (e.g. running the OSS gem on a
            # shared/cloud host where a fetched page must not probe the network).
            "allow_private_network" => true
          }
        },
        "tool_output" => {
          "max_bytes" => 50_000,
          "max_lines" => 2000,
          "max_line_length" => 2000,
          # Hard RAM ceiling on what the shell tool RETAINS while draining a
          # subprocess pipe (#539). Independent of `max_bytes` (the model-facing
          # truncation budget): an unbounded producer (`cat /dev/zero`, `yes`)
          # emits faster than we can shape, so the capture seam keeps at most a
          # bounded head+tail of this many bytes and KILLS the producer once the
          # cap is hit — RAM stays bounded no matter how much the process emits.
          # Sized well above max_bytes so the downstream truncate still has its
          # full head/tail budget, but small enough to never OOM the agent.
          "capture_max_bytes" => 2_000_000
        },
        # Deterministic, REVERSIBLE compression of tool output, routed through
        # the single Compression::ContentRouter seam in the ToolExecutor. The
        # master `enabled` flag gates the whole seam; the per-type sub-config
        # (`code`, `logs`) tunes each strategy. When on, the router DETECTS the
        # content type and dispatches: a test/build/lint dump → LogCompressor
        # (every failure + summary kept, passing noise dropped); a WHOLE-file
        # Ruby read → skeleton (signatures + small bodies verbatim, large bodies
        # elided behind a pointer that IS a targeted `read offset/limit`). A
        # diff, a grep/search result, and short output PASS THROUGH byte-
        # identical, so exact-string anchors edit/grep rely on are never touched.
        # On any compression the full original is spilled to
        # tool-results/<call_id>.txt and the output ends with a pointer the model
        # can `read` back. OFF by default: with this flag false every tool output
        # is byte-for-byte unchanged. Per-call `compress:false` on read/shell
        # forces verbatim output even when enabled.
        "tool_output_compression" => {
          "enabled" => false,
          "code" => {
            "strategy" => "skeleton",
            # Don't bother skeletonising a file shorter than this many lines —
            # the pointer indirection isn't worth it on small files.
            "min_lines" => 150,
            # Method bodies up to this many lines are kept VERBATIM; only larger
            # bodies are elided behind a pointer.
            "keep_method_body_max_lines" => 8,
            # Which source languages get skeletonised. Remove one ⇒ no compression
            # for it (its whole-file reads pass through verbatim). Ruby uses the
            # built-in Prism parser; other languages added in later slices need
            # their own parser before they can be enabled here.
            "languages" => %w[ruby]
          },
          # LOG/command-output compression (test runs, linters, build/shell
          # dumps). The high-ROI channel: the agent reads command output WHOLE,
          # and the signal (failures + the final tally) is a tiny fraction of the
          # bytes. Keeps every error/failure + summary VERBATIM, drops passing/
          # info noise, appends a pointer to retrieve the original. OFF by default
          # (own flag, independent of `code`) — we measure before flipping it on.
          "logs" => {
            "enabled" => false,
            # Outputs shorter than this pass through UNCHANGED.
            "min_lines" => 40,
            # Hard cap on kept lines.
            "max_total_lines" => 100,
            # Keep every error/failure up to this many (first & last always).
            "max_errors" => 10,
            "max_warnings" => 5,
            "max_stack_traces" => 3,
            # Lines of surrounding context kept around each failure.
            "context_lines" => 4
          },
          # DIFF compression (model-facing `:output` of a `git diff` / unified
          # diff). The human view is the tool `:body` (the full coloured diff in
          # scrollback) and is NEVER touched — only the model's copy is trimmed.
          # No own `enabled` flag (like `code`): active when the master flag is
          # on; the saving guard below is the real gate. Keeps every +/- line and
          # every file/hunk header; trims far context and elides generated/lock
          # files. A small/tight diff passes through byte-identical automatically.
          "diff" => {
            # Unchanged context kept on each side of a change; far context is
            # collapsed into a `… N unchanged lines` marker.
            "context_lines" => 3,
            # Diffs shorter than this pass through UNCHANGED (the common
            # "show me the diff" case the human wants to see verbatim).
            "min_lines" => 40,
            # Only apply when the compressed result is at least this much
            # smaller; otherwise byte-identical passthrough.
            "min_saving" => 0.25,
            # Changed files matching any of these collapse to a one-line summary
            # (`path: +X/-Y lines, N hunks — elided (generated)`). A trailing `/`
            # matches a directory; a `*` glob matches the basename.
            "generated_patterns" => %w[
              *.lock Gemfile.lock package-lock.json yarn.lock pnpm-lock.yaml
              composer.lock *.min.js *.min.css dist/ build/ *.snap vendor/
            ]
          },
          # JSON compression (a whole-output JSON dump from a tool — `curl | jq`,
          # `kubectl get -o json`, `gh api`, `docker inspect`, `aws --output
          # json`, or an MCP/custom-tool JSON result). Modelled on headroom's
          # SmartCrusher: an array of UNIFORM objects folds LOSSLESSLY to a
          # schema header + one compact row per item (the repeated key names are
          # emitted once); a large array whose fold is too thin falls back to
          # LOSSY row selection where error-bearing rows and statistical outliers
          # always survive and dropped rows collapse to an `{"_elided": N}`
          # sentinel; a single large object elides only big string values and
          # never drops a key. No own `enabled` flag (like `code`/`diff`): active
          # when the master flag is on; the saving guard below is the real gate,
          # so small JSON the model wants verbatim passes through byte-identical.
          # Detection runs BEFORE the log channel — a whole-output JSON dump from
          # `shell` routes here, never to the log compressor.
          "json" => {
            # Arrays with fewer than this many items (and text shorter than
            # min_lines) pass through UNCHANGED — small JSON stays verbatim.
            "min_items" => 8,
            # Objects / text shorter than this many lines pass through unchanged.
            "min_lines" => 40,
            # Only apply when the compressed result is at least this much smaller;
            # otherwise byte-identical passthrough.
            "min_saving" => 0.25,
            # A numeric field more than this many standard deviations from its
            # column mean marks a row as a statistical outlier (kept in the lossy
            # fallback).
            "outlier_sigma" => 3.0,
            # In a single large object, string values longer than this collapse
            # to a `<elided N chars>` placeholder (the key is always kept).
            "max_string_chars" => 400
          }
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
            # Decompression-bomb / runaway-conversion caps for the in-process
            # document converters (Documents::Limits). The 25 MB on-disk
            # max_file_bytes is trivially defeated by zip compression (a 100 KB
            # .docx expands to ~34 MB of XML / 1M paragraphs), so the converter
            # caps BEFORE/DURING conversion: a paragraph/row/page/slide count
            # ceiling, an accumulated decompressed-bytes ceiling (also checked
            # against the OOXML central directory BEFORE the gem inflates), and
            # a wall-clock budget. On any cap it bails to the shell-extraction
            # hint instead of hanging / OOM-killing the turn.
            "convert_max_elements" => 50_000,
            "convert_max_decompressed_bytes" => 5_000_000, # ~5 MB extracted text
            "convert_wall_clock_seconds" => 15.0,
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
          #   dangerous_only (DEFAULT, reference-faithful) safe commands run
          #                  unprompted; only DangerousPatterns matches prompt.
          #   confirm_all    (opt-in hardening) every such command prompts.
          # Aligned to Hermes (#409): Hermes has no confirm-policy concept —
          # detect_dangerous_command is its SOLE prompt trigger; non-dangerous
          # commands run unprompted. The old confirm_all default prompted on
          # every npm test / make / ls — huge DX friction. The hardline floor
          # and permissions:deny always precede this regardless of policy, so
          # dangerous_only never weakens the non-bypassable floor. Set
          # confirm_policy: "confirm_all" to restore prompt-on-everything.
          "confirm_policy" => "dangerous_only",
          # EMPTY by default (#409), aligning to Hermes' empty allowlist: once
          # the prompt policy is dangerous_only, safe commands (incl. git status
          # / git diff) already run unprompted via the policy + read-only
          # auto-allow, so the seeded entries were non-load-bearing. A
          # code-loading runner (`bundle exec rspec`, `rake`, `npm test`) is
          # still NOT safely allowlistable (SEC-R2-3: `rspec -r FILE` is RCE);
          # users who want exact-command pre-approval opt in explicitly.
          "command_allowlist" => [],

          # Redact credential VALUES (API keys, tokens, private keys, DB
          # passwords, JWTs…) from tool output before it enters context, the
          # transcript, or the aux model. ON by default (secure default,
          # Hermes #17691). Applied to read (text AND converted documents) /
          # grep / shell / shell_manage content via
          # Security::Redactor. Set
          # false ONLY when you need raw credential values in tool output
          # (e.g. working on the redactor itself). NOT a security boundary —
          # the shell runs as the same OS user; this is defense-in-depth.
          "redact_secrets" => true,

          # Pluggable redaction: bring your own redactor class and/or
          # additive custom regex patterns (in addition to the built-in set).
          "redaction" => {
            # "class" => "MyApp::PrivacyRedactor",  # optional custom redactor
            # "custom_patterns" => []                # additional regex patterns
          },

          "website_blocklist" => {
            "enabled" => false,
            "domains" => [],
            "shared_files" => []
          }
        },
        # Repeated-identical-tool-call guard (DoomLoopDetector). Aligned to
        # Hermes' tool_guardrails (#414): hard_stop OFF by default (WARN, don't
        # block) and a higher threshold, so a legitimate 3rd retry of an
        # idempotent read is no longer hard-denied. With hard_stop:false the
        # policy surfaces a doom-loop WARNING to the model on the Nth identical
        # call but still lets it through; set hard_stop:true to restore the old
        # block-at-threshold behaviour.
        "doom_loop" => {
          "hard_stop" => false,
          "threshold" => 5
        },
        "privacy" => {
          "redact_pii" => false
        },
        # Opt-in OpenTelemetry tracing (Rubino::Telemetry). When enabled — and
        # the optional `opentelemetry-sdk` + `opentelemetry-exporter-otlp` gems
        # are installed — rubino exports spans following the OTel GenAI
        # semantic conventions over OTLP http/protobuf: `invoke_agent` per
        # turn, `chat <model>` per model call (gen_ai.usage.* token counts,
        # prompt-cache reads included) and `execute_tool <name>` per tool call.
        #   endpoint — collector base URL or full /v1/traces URL. nil ⇒ the
        #     standard OTEL_EXPORTER_OTLP_* env vars, then the SDK default
        #     (http://localhost:4318).
        #   headers — extra exporter headers (e.g. an auth token; supports
        #     ${ENV_VAR} expansion like every config value).
        #   environment — stamped as deployment.environment.name on the
        #     resource (dev/staging/prod).
        #   capture_content — PRIVACY GATE, default OFF: message/tool text is
        #     NEVER exported unless this (or the standard
        #     OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true env var)
        #     opts in; even then payloads pass Logger.redact and are truncated.
        #   resource_attributes — extra key/value resource attributes attached
        #     to every span (team, host role, …).
        "otel" => {
          "enabled" => false,
          "endpoint" => nil,
          "headers" => {},
          "environment" => nil,
          "capture_content" => false,
          "resource_attributes" => {}
        },
        # #552: how long an interactive `question`/clarify waits for the human
        # before it EXPIRES CLEANLY (the agent proceeds with its best judgement),
        # mirroring Hermes' agent.clarify_timeout.
        # Generous (10 min) — long enough to read a multi-option menu and answer,
        # short enough that an abandoned prompt eventually unblocks the run. This
        # is the BLOCKING-tool wait bound; the stale-chunk watchdog is separately
        # suspended for the tool's whole runtime (RubyLLMAdapter#stream_once), so
        # it never pre-empts this timeout.
        "clarify" => {
          "timeout" => 600
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
        #   prompts.prompt_cache — when true (default) the assembler emits
        #     Anthropic prompt-cache breakpoints (cache_control) on the stable
        #     system prefix and the last tool definition, so the fixed prompt
        #     prefix + tool block are cached across turns (#311). The volatile
        #     tail (fresh relevant-memories + post-compaction summary) is kept
        #     AFTER the system breakpoint so the cached bytes stay byte-stable.
        #     Honored by anthropic-family providers; other providers ignore it.
        "prompts" => {
          "preamble" => nil,
          "environment" => {
            "enabled" => true,
            "extra_utilities" => []
          },
          "overrides" => {},
          "prompt_cache" => true
        },
        "quick_commands" => {},
        "mcp" => {
          "servers" => {}
        },
        "skills" => {
          "enabled" => true,
          # Post-turn background skill review. When true, every N turns a
          # successful turn enqueues BackgroundReviewJob — the Hermes-style fork
          # that replays the conversation (reusing the warm KV prefix, so no
          # freeze) and lets a restricted review agent decide whether to capture
          # a reusable SKILL.md. A separate toggle from `enabled` (which only
          # controls whether skills are loaded/usable) so a deployment — or a
          # test that scripts a fixed number of LLM turns — can keep skills
          # usable while turning the background review off. (Key name kept for
          # config back-compat with the earlier distillation implementation.)
          "auto_distill" => true,
          # Throttle the background skill review to ~every N turns (#414),
          # mirroring memory.auto_extract_interval and Hermes' skill
          # nudge_interval, so a session doesn't fork a review every single turn.
          # nil/<=1 = every eligible turn.
          "auto_distill_interval" => 10,
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
          "rate_limit_auth_per_minute" => 600,
          # SAFE BY DEFAULT (#577). The API can execute shell tools, so binding
          # it to a non-loopback address (--host 0.0.0.0 / RUBINO_API_HOST set to
          # anything other than 127.0.0.1 / ::1 / localhost) publishes an
          # RCE-capable surface to the network. TLS is off by default, so the
          # bearer token and all traffic would travel in cleartext. Booting on a
          # non-loopback host is therefore REFUSED unless this is explicitly set
          # to true; loopback binds are unaffected. When you do opt in, enable
          # TLS (RUBINO_TLS=1) + a strong RUBINO_API_KEY and prefer a reverse
          # proxy over exposing the listener directly.
          "allow_public_bind" => false
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
