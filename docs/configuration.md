# Configuration Reference

All values below are checked against `lib/rubino/config/defaults.rb` (`MODULE_DEFAULTS`) — the single source of truth. Only keys that ship a default are shown with one; everything else is opt-in.

## File Locations

- **Config:** `~/.rubino/config.yml` (created by `rubino setup`)
- **Secrets:** `~/.rubino/.env`
- **Database:** `~/.rubino/rubino.sqlite3`

> **`RUBINO_HOME` relocates everything.** When set, the home directory, `config.yml`, `.env`, and the database all follow it (the `database.path` default is a sentinel resolved at read time against the resolved home — issue #96). The CLI and the API server share one resolver, so they never disagree about where state lives.

> **Config is GLOBAL — there is no project-local `config.yml` (#50).** `Config::Loader` reads exactly ONE `config.yml`, under the resolved home (`RUBINO_HOME`, else `~/.rubino`), shared by every rubino invocation on the machine; `/config set` (or `rubino config set`) in one session changes the setting for all of them. A `.rubino/config.yml` dropped into a project directory is **not read** — per-project config is a separate, unbuilt feature, not the current contract. This is distinct from **skills** and **commands**, which DO support a project-local directory alongside the user one (`.rubino/skills` / `.rubino/commands` — see their sections below); only the main `config.yml` is global-only.

## Precedence (highest to lowest)

1. User global `~/.rubino/config.yml`
2. Built-in defaults

`RUBINO_HOME` changes WHERE that single `config.yml` lives — it is not a second override layer. There is no generic `RUBINO_*`-env-var-per-config-key mechanism; the specific environment variables listed at the bottom of this page (provider keys, `RUBINO_API_KEY`, etc.) are read directly by the code that uses them, not merged over `config.yml` as a precedence tier.

## Substitutions

Use in any string value:
- `{env:VAR_NAME}` or `${VAR_NAME}` — inserts an environment variable
- `{file:path/to/file}` — inserts file contents

---

## Full Config Reference

### model

```yaml
model:
  default: "openai/gpt-4.1"     # Model identifier (resolves to OpenAI's own API, no OpenRouter hop — see models-and-keys.md)
  provider: "auto"              # auto | openai | anthropic | bedrock | gemini | minimax | gateway
  context_length: null          # Override context window (null = use model default)
  temperature: null             # null = inherit the provider default (no temperature is sent)
  max_tokens: null              # Max output tokens (anthropic-family path); null = adapter default (16384)
  thinking_budget: null         # LEGACY — superseded by thinking.effort (below); null = adapter default (8000), 0 disables
  max_tokens_text_headroom: 4096  # Visible-output headroom reserved on top of the thinking budget
  supports_vision: null         # null = auto-detect from model id; true/false to override
```

> The shipped default `openai/gpt-4.1` resolves to OpenAI's own API under `provider: auto` — rubino's own id-prefix resolver (`LLM::ProviderResolver`) picks the provider, not ruby_llm's model registry, so there is no OpenRouter hop. See [models-and-keys.md](models-and-keys.md) for the per-provider blocks and the fail-fast behavior.

### providers

```yaml
providers:
  openai:
    base_url: null                     # Custom endpoint (Azure, proxy)
    request_timeout_seconds: 600       # Per-read socket inactivity timeout (resets per chunk)
    stale_timeout_seconds: 300         # Stale connection timeout
  anthropic:
    base_url: null
    request_timeout_seconds: 600
  bedrock:
    region: "us-east-1"
    request_timeout_seconds: 600
  gemini:
    request_timeout_seconds: 600
  gateway:                         # OpenAI-compatible gateway
    openai_compatible: true
    assume_model_exists: true
    base_url: null
    request_timeout_seconds: 600
    extra_body: {}                 # free-form body merged into /v1/chat/completions
```

Per-provider you may also set `api_key`, and for custom gateways `anthropic_compatible: true` (MiniMax) or `openai_compatible: true`. See [models-and-keys.md](models-and-keys.md).

#### `extra_body` — OpenAI-compatible request passthrough

`providers.<name>.extra_body` is a free-form hash deep-merged verbatim into the OpenAI-style `/v1/chat/completions` request body. It is honored **only on the OpenAI-compatible request path** (`openai_compatible: true`, or the native `openai` provider) and is never applied on the anthropic-family path, nor does it touch the thinking-budget logic. Adapter-routed keys (`max_tokens`, `thinking`) win on conflict. Left unset (the default `{}`) the request is byte-identical to before.

Use it to pass provider-specific knobs the adapter does not model natively. The canonical case is suppressing chain-of-thought leakage on oMLX / Qwen-style backends that emit `<think>` text instead of native `tool_calls` unless the request carries `chat_template_kwargs: { enable_thinking: false }`:

```yaml
providers:
  gateway:
    openai_compatible: true
    base_url: "http://localhost:8000/v1"
    extra_body:
      chat_template_kwargs:
        enable_thinking: false
```

Per-provider `supports_thinking: true | false` declares whether the backend handles an Anthropic-style thinking budget correctly; `false` means no budget is ever sent to it, regardless of `thinking.effort`. Unset, MiniMax-family model ids default to `false`, everything else to `true` — see [reasoning & thinking](#reasoning--thinking).

### auxiliary

```yaml
auxiliary:
  compression:
    provider: "main"     # "main" uses default model
    model: ""            # Specific model for compression
    base_url: null
    timeout: 120
  vision:                # `vision` tool delegates here so a text-only primary can "see"
    provider: "main"
    model: ""            # "auto-vision" lets an OpenAI-compatible gateway pick
    base_url: null
    timeout: 120
  summarize:             # used by skill distillation and oversized-document reads (the `read` tool)
    provider: "main"
    model: ""
    base_url: null
    timeout: 300
  title:                 # session titling; deterministic unless a concrete non-"main" backend is set here
    provider: "main"
    model: ""
    base_url: null
    timeout: 30
```

> **`auxiliary.embedding` ships no default block** — it is fully opt-in and only
> read when `memory.sqlite.vector: true` (inert otherwise). Point it at a local
> embedding model (e.g. an oMLX/Ollama endpoint) for semantic recall with no paid
> API. Add the block yourself:
>
> ```yaml
> auxiliary:
>   embedding:
>     provider: "main"    # "main" reuses the primary provider; set "openai"/"ollama" for local
>     model: ""           # e.g. "bge-m3", "nomic-embed-text", "text-embedding-3-small"
>     base_url: null      # local endpoint URL (e.g. "http://localhost:8080/v1")
>     timeout: 30
> ```

Each block routes through `LLM::AuxiliaryClient`, so `provider`/`model`/`base_url`
are all honored: `provider: "main"` (or empty) reuses the primary provider, an empty
`model` falls back to `model.default`, and a `base_url` points that task at a
different endpoint. `auxiliary.compression` is the **context-compaction summary**
model — at the defaults it is the primary model (e.g. the shipped default
`openai/gpt-4.1`), unchanged; set `provider`/`model`/`base_url` to run
compaction summaries on a different (OpenAI-compatible) endpoint.

### chat

```yaml
chat:
  auto_resume: true   # Bare `rubino chat` (no --new/--resume/--continue) resumes the last
                       # session for the launch dir instead of starting fresh. Set to false
                       # to make a bare `chat` always start new (explicit --resume/--continue
                       # /--session are unaffected either way).
```

### agent

```yaml
agent:
  max_turns: 90                              # Outer rail on tool iterations per turn
  max_tool_iterations: 90                    # Max per-turn model<->tool round-trips (cap; --max-turns overrides)
  budget_extension_prompt: true              # At the cap, prompt continue/summarize/abort (interactive only)
  budget_extension_step: null                # "+N" per extension (null = max_tool_iterations)
  max_turn_seconds: null                     # Safety-net wall clock per turn; null = disabled (iteration budget is the guard)
  api_max_retries: 5                         # LLM API retry count (exp backoff)
  api_retry_backoff_cap_seconds: 16          # Max per-retry backoff draw
  api_retry_total_timeout_seconds: 30        # Total wall-time budget across error-path retries (null = no total cap)
  api_retry_backoff_overload_cap_seconds: 60 # Higher cap used only for overload (529/503)
  empty_response_max_retries: 2              # In-turn retries for a 200-OK-but-empty response
  fallback_models: []                        # Ordered provider/model fallback chain (empty = none)
  disabled_toolsets: []                      # Tool names to disable
  tool_use_enforcement: "auto"
```

### run

```yaml
run:
  idle_event_timeout: 300   # SSE watchdog: mark a stalled run failed after N idle seconds (null = off)
```

### database

```yaml
database:
  path: "<RUBINO_HOME>/rubino.sqlite3"  # sentinel; resolved against the home at read time
```

An explicit `path` in `config.yml` is used verbatim and overrides the sentinel.

### paths

```yaml
paths:
  home: "~/.rubino"
  memory: "~/.rubino/memories"
  skills: "~/.rubino/skills"
  cron: "~/.rubino/cron"
  sessions: "~/.rubino/sessions"
  logs: "~/.rubino/logs"
```

### ui

```yaml
ui:
  adapter: "cli"       # cli | api | null
  theme: "default"     # default | dark | light | monokai
  verbose: false
```

### notifications

Attention signals for the moments the agent needs human eyes: a long turn finishing, or an approval prompt parking the run on a decision (the main agent's card or a background subagent flipping to `needs_approval`).

```yaml
notifications:
  enabled: true          # master switch for all attention signals
  bell: true             # terminal bell (BEL) per event; on iTerm2 an OSC 9 escape is also sent (native macOS notification)
  command: null          # optional shell command spawned non-blocking per event, e.g. "osascript -e \"display notification ...\""
  min_turn_seconds: 10   # a turn must run at least this long before its completion notifies; quick turns stay silent
```

- **Events**: `turn_finished` (only when the turn ran ≥ `min_turn_seconds`), `needs_approval` (the main agent's approval card or a background child flipping to `needs approval`). These are the only two events `UI::Notifier` emits.
- **Bell hygiene**: the BEL byte is only ever written to a real terminal — never into a pipe — and is routed to the real terminal IO even while the bottom composer owns the screen (BEL doesn't move the cursor).
- **`command` hook**: runs detached and best-effort (stdio nulled, errors swallowed to the log) with `RUBINO_EVENT` (`turn_finished` | `needs_approval`) and `RUBINO_MESSAGE` in its environment — the seam for `osascript` (macOS), `notify-send` (Linux), or any custom notifier.
- **Spam control**: events within ~1s of the last emitted one coalesce into a single signal.

### reasoning & thinking

Two orthogonal first-class knobs — these are what `/reasoning` and `/think` write:

```yaml
display:
  reasoning: collapsed   # hidden | collapsed | full — how reasoning is RENDERED

thinking:
  effort: "off"          # "off" | low | medium | high — how hard the model thinks
```

- `display.reasoning` controls rendering: `hidden` (nothing shown; Ctrl+O can still reveal the last thought), `collapsed` (default — a dim "✻ thought for Ns · ctrl-o to show" cue), `full` (the whole reasoning as a dim `┊` aside).
- `thinking.effort` maps to an Anthropic-style thinking-token budget (`off`→0, `low`→4000, `medium`→8000, `high`→16000) on the anthropic-family path. Unset (`null`) falls back to the `thinking_budget` chain, whose default is 8000 — i.e. the effective default effort is `medium`.
- **Quote `"off"`**: bare YAML `off` parses as the boolean `false`. The reader coerces `false` back to `off`, but quoting keeps `config get thinking.effort` honest.
- **Provider caveat**: some anthropic-compatible backends reject thinking budgets. The adapter detects the rejection, retries the turn once without the budget, and prints `provider doesn't support thinking — effort off` — set `effort: "off"` to skip the first-turn retry entirely.
- **Provider capability gate**: other backends *accept* the budget but, lacking a separate reasoning channel, dump the model's chain-of-thought as plain content — the reasoning appears inside the assistant message. `providers.<name>.supports_thinking: false` stops the budget from ever being sent to that backend, regardless of `thinking.effort`. Unset, MiniMax-family model ids (`MiniMax*`/`abab*`) default to `false` (they return no thinking blocks and leak reasoning when sent a budget); set `supports_thinking: true` explicitly to re-enable. For a model outside ruby_llm's registry (`assume_model_exists`, e.g. MiniMax on the anthropic-compatible path) the explicit opt-in sends the Anthropic-style `thinking` block via raw request params — ruby_llm's `with_thinking` only renders for registry models that declare a budget reasoning option and would otherwise raise client-side, silently killing the opt-in.

The legacy `display.show_reasoning` boolean maps in only when `display.reasoning` is unset (`true`→full, `false`→hidden); `model.thinking_budget` is likewise superseded by `thinking.effort`.

### streaming

```yaml
display:
  streaming: true
  reasoning: collapsed   # NOT seeded in defaults.rb — ReasoningPrefs supplies "collapsed"; see "reasoning & thinking" above
  show_reasoning: true   # LEGACY, NOT seeded — superseded by display.reasoning (maps in only when reasoning is unset)
  language: "en"
  runtime_footer: { enabled: false }
  interim_assistant_messages: false
  statusbar: true        # the model + context bar under the chat input
  tool_output_preview_lines: 3  # head lines of tool output shown in the transcript (0 = full dump)
  input_max_rows: 8      # chat input grows up to this many rows, then scrolls
  live_markdown: true    # format the in-flight streamed block live (false = raw live tail)
  synchronized_output: true  # atomic frames via DEC-2026 BSU/ESU (false = legacy per-write frames)
  code_highlight: true       # syntax-highlight committed code blocks (Rouge); false = plain

paste:
  collapse_lines: 5            # pastes longer than this collapse to a placeholder
  collapse_chars: 400          # a paste longer than this many CHARS also collapses to the chip,
                               # even on a single line (a big one-line URL/token/minified JSON)
  file_threshold_tokens: 8000  # bigger pastes overflow to a session paste_N.txt

streaming:
  enabled: true

context:
  engine: "compressor"
  max_tokens: null
```

- `display.statusbar` (default `true`) pins a dim one-line bar UNDER the chat input — the session mode first (plus the branch/skill tokens when set), then the resolved model id and context saturation, e.g. `default · MiniMax-M3 · ctx ~8.4k/64k (13%)` (the percentage is omitted below 1%). The mode token is the live mode indicator (the prompt itself is a constant `▍❯ `): dim `default`, yellow `plan`, red `yolo`. Saturation uses the REAL usage the provider reported for the last response when available (the full assembled prompt, recorded by the agent loop), else the same chars/4 estimate compaction runs on (`Context::TokenBudget`); the window comes from `model.context_length` / `context.max_tokens`. It refreshes at turn boundaries (after each turn footer, and on session resume), never per stream delta. The percentage turns yellow at 70% and red at 90%; with no usable window only the token count shows. The bar is omitted off a TTY or on terminals narrower than 40 columns.
- `display.tool_output_preview_lines` (default `3`) caps how many head lines of each tool's output the transcript shows before a dim `… +N lines (full output → context)` marker. DISPLAY-ONLY: the model always receives the full output (subject to the `tool_output` truncation caps) — only the scrollback rendering collapses. Set `0` to restore the old full dump.
- `display.input_max_rows` (default `8`) caps how many visual rows the chat input grows to as a long or multi-line prompt wraps; past the cap the input scrolls vertically, keeping the caret row in view.
- `display.live_markdown` (default `true`) renders the still-streaming (in-flight) block as FORMATTED markdown in the live region — bold, headings, lists and code style as the tokens arrive, with syntax left open by the partial stream repaired (an open code fence shows as a code block, a dangling `**`/`` ` `` span is closed) so no raw marker leaks. Set `false` for the legacy raw rolling-tail that only snaps to styled when the block commits. Display-only; the committed scrollback render is identical either way.
- `display.synchronized_output` (default `true`) wraps each live-region frame in DEC private mode 2026 (BSU/ESU synchronized output) so a supporting terminal (kitty, WezTerm, tmux ≥3.4, recent xterm.js) buffers the whole clear→commit→redraw sequence and swaps it in one atomic update — no flicker or tearing on multi-step repaints. Terminals without support silently ignore the mode (it degrades cleanly); the escapes are emitted only to a real TTY. Set `false` for the legacy per-write frames.
- `display.code_highlight` (default `true`) syntax-highlights fenced code blocks by language (via Rouge) in the COMMITTED render — the live tail stays unstyled, so highlighting never blocks the stream (code shows instantly, colours arrive a beat later when the block commits, like Claude Code). Unknown languages, language-less fences, and any failure fall back to the plain code body. Set `false` for plain (uncoloured) code blocks.
- An **unterminated** code fence at end-of-stream — a fence the model never closed, or closed with a too-short bare run of backticks (e.g. MiniMax-M3 emitting `` against a ``` opener) — is rendered as a code box, matching CommonMark's end-of-document auto-close (§4.5) that every other renderer relies on. The CLI synthesises the close at the opener length (never relaxing the "close ≥ opener" rule), because kramdown does not auto-close an open fence.
- `paste.collapse_lines` (default `5`) — the file-backed paste pipeline's first tier. Pasting MORE than this many lines into the chat input inserts a single cyan `[Pasted text #N +M lines]` placeholder instead of flooding the composer; the placeholder is one editable token (backspace deletes it whole, you can type around it, it survives ↑ draft recall and Alt+Enter queueing) and expands to the full pasted body when the message is sent — the model sees everything, while the transcript echo keeps the compact placeholder. Pastes at or under the threshold inline as real rows, exactly as before.
- `paste.file_threshold_tokens` (default `8000`) — the second tier. A paste estimated above this many tokens (chars/4, the same rule compaction uses) is written to `<RUBINO_HOME>/sessions/<session-id>/paste_N.txt` instead of being held inline, and the sent message carries `[Pasted text #N saved to <path> — too large to inline; read it with the read tool]` so the model reads just the parts it needs. The files persist for the session; `/clear-images` does not touch them (it only drops staged image attachments).

### compression

```yaml
compression:
  enabled: true
  threshold: 0.50              # Trigger at 50% of context window
  target_ratio: 0.20           # Compress to 20% of window
  protect_first_n: 3           # Keep first N messages
  protect_last_n: 20           # Keep last N messages
  max_summary_tokens: 12000
  preserve_tool_pairs: true
```

### memory

```yaml
memory:
  enabled: true
  backend: "sqlite"          # SQLite FTS5/BM25 + graph-lite recall (default). "default" = legacy non-ranked store
  auto_extract: true         # agentic fact mining via the review fork (BackgroundReviewJob)
  auto_extract_interval: 10  # throttle inter-turn extraction to ~every N turns (nil/<=1 = every turn)
  auto_save: true
  user_profile_enabled: true
  project_context_enabled: true  # AGENTS.md/CLAUDE.md/.rubino.md/.cursorrules file discovery,
                                  # injected as "# Project Context" (unrelated to the SQLite
                                  # backend's "project"/"env" kind facts, which recall from the
                                  # same global pool as everything else — see docs/memory.md)
  memory_char_limit: 2200    # injection budget at RETRIEVAL time
  user_char_limit: 1375
  ingest_char_limit: null    # cap on the live set at STORE time (null = unbounded)
  extract_max_retries: 3     # bounded retry budget for the aux extraction call on a transient
                             # error (429/overloaded/5xx), honouring Retry-After — so a fact
                             # isn't lost to a transient rate limit
  sqlite:
    vector: false            # opt-in sqlite-vec/embedding KNN on top of FTS5 (needs RubyLLM.embed)
    graph: true              # graph-lite 1-hop entity/edge blend
    graph_extraction: "deterministic"  # how the entity graph is FED: "deterministic" (default —
                             #   pure-Ruby proper-noun/identifier heuristic, no LLM), "supplied"
                             #   (only entities the memory tool call carries), "off" (never feed it)
```

See [memory.md](memory.md) for the backend internals.

### jobs

```yaml
jobs:
  mode: "inline"              # inline | manual | worker
  poll_interval: 2            # Worker poll interval (seconds)
  max_attempts: 3
  retry_backoff_seconds: 30
  lock_lease_seconds: 900     # how long a CLAIMED (running) row may stay locked before it's
                              # presumed abandoned and reclaimed (attempts bumped) — a worker that
                              # dies/hangs after claiming a row would otherwise leave it stuck (#76)
```

### cleanup

Opportunistic session/spill cleanup at startup (not a cron job), throttled to at most once per 24h — deletes ENDED sessions older than `period_days` plus their spill files.

```yaml
cleanup:
  period_days: 30        # retention window (days). nil / false / "off" / 0 / negative = OFF.
                         #   Do NOT overload 0 as "retain forever" — use nil/false/"off".
  min_retention_days: 1  # floor: newer sessions are UNTOUCHABLE regardless of status
```

### tasks

Caps on the nested-subagent (`task` delegation) tree, all enforced in one place (`Tools::BackgroundTasks#reserve`). See [agents.md](agents.md#nesting-and-caps) for the model.

```yaml
tasks:
  max_depth: 2                   # max nesting depth (human → child → grandchild)
  max_children_per_node: 3       # max LIVE direct children per node
  max_concurrent_total: 8        # hard ceiling on total LIVE subagents across the tree
  max_live_probes_per_child: 5   # per-child budget for billed live probes (probe(live: true))
```

### tools

```yaml
tools:
  recover_text_tool_calls: true  # re-parse tool calls a model LEAKS AS TEXT (markup in
                          # assistant content) back into real tool calls, and strip them
                          # from saved history. Covers Hermes/Qwen JSON, MiniMax/Qwen3-Coder
                          # XML, Mistral arrays. Inert when native tool calls exist. false = off
  workspace_strict: true  # Sandbox write/edit/delete to workspace_root; false = any reachable path
  shell: true             # ON by default (the agent ships to run inside an isolated VM);
                          # dangerous commands are still gated by security.confirm_policy
  ruby: true
  web: true               # ON by default (keyless DuckDuckGo backend); gates BOTH the web_fetch and web_search tools
  memory: true
```

Each tool declares its own `tools.<key>` gate (`Tools::Base#config_key`). A key
absent from config means the tool is enabled (opt-out model); only an explicit
`false` disables it. So the keys above are the ones that ship a default — file
tools (`read`/`write`/`edit`/`grep`/`glob`) and the
rest are on by default and don't need a config entry. Note
both web tools share a single gate: `tools.web` controls `web_fetch` **and**
`web_search` (there is no `tools.web_fetch` / `tools.web_search`).

#### tools.sandbox (OS write-jail)

```yaml
tools:
  sandbox:
    mode: workspace-write   # off | read-only | workspace-write (default)
    network: allow          # slice 1; deny/proxy are later
    extra_writable: []       # extra absolute paths added to the write jail
    require: false          # true = FAIL-CLOSED: shell refuses to run when no
                            #        OS mechanism is available (default fails OPEN)
    escalation: protect-home # off | protect-home | full  (see below)
    devices:                # macOS/Seatbelt only (Linux/Landlock ignores it)
      gpu:
        mode: allow         # allow (default) — IOKit user-clients added to every sandboxed
                            #   spawn so a jailed command can reach the GPU (Metal/MLX/MPS).
                            #   deny — never added (lock-down); a GPU command fails "No Metal device".
                            # ALWAYS-ON knob, no per-command prompt (grants no fs-write/network)
        iokit_user_clients: # user-client classes appended to the profile; add one to add a device
          - AGXDeviceUserClient
          - IOGPUDeviceUserClient
          - IOSurfaceRootUserClient
          - IOSurfaceSendRight
          - AppleGraphicsDeviceControlClient
```

The OS write-jail confines shell (and `ruby`) **writes** at the kernel level —
Seatbelt on macOS, Landlock on Linux — so a write outside the workspace fails
even if it slips past the command allowlist. Reads stay broad. `~/.rubino` is
**deliberately non-writable** from the jailed shell: it holds the sandbox's own
trust anchors (config, `.env`, the session DB, the Landlock/Seatbelt helper,
skills). Manage skills with the `skill` tool, not a shell `rm`.

`escalation` governs the `disable_sandbox` escape hatch — re-running a command
**outside** the jail after **explicit approval** when a write-jail denial blocked
a legitimate out-of-workspace write:

| value | behaviour |
| --- | --- |
| `off` | no hatch; `disable_sandbox` is ignored and a jailed write hard-fails (Claude Code `allowUnsandboxedCommands:false` / Codex `Never`). |
| `protect-home` | **default.** An approved escalation runs UNCONFINED on every platform — the approval prompt (step 4b) is the only boundary. `~/.rubino` is NOT OS-blocked during escalation; the human decides. |
| `full` | Codex-style: an approved escalation is fully unconfined (`SandboxType::None`) — the human approval is the only boundary, no OS floor on `~/.rubino`. |

An escalated command **always** prompts (a fresh, distinct approval that shows it
runs outside the jail), sits below `--yolo` and below the non-bypassable hardline
floor (`rm -rf /` is still denied), and fails closed in a headless session.

#### tools.webfetch (headless-browser fallback + private-network reach)

```yaml
tools:
  webfetch:
    js_rendering: "auto"          # auto (default) | off | always — when the web_fetch tool
                                  #   renders a JS/SPA page in a headless browser. "auto" renders
                                  #   only when the static response scores as a client-rendered
                                  #   shell; "off" never; "always" every page (slower). Only ever
                                  #   engages when the OPTIONAL ferrum gem + a Chrome/Chromium
                                  #   binary are present — otherwise this whole block is inert.
    allow_private_network: true   # let web_fetch reach loopback/LAN (localhost dev servers,
                                  #   internal services) — rubino is a LOCAL dev agent. The
                                  #   cloud-metadata floor (169.254.169.254 …) stays blocked
                                  #   regardless. false = strict public-only fetching.
```

### tool_output

```yaml
tool_output:
  max_bytes: 50000
  max_lines: 2000
  max_line_length: 2000
  capture_max_bytes: 2000000   # hard RAM ceiling on what the shell tool RETAINS while draining a
                               # subprocess pipe (independent of max_bytes). An unbounded producer
                               # (`cat /dev/zero`, `yes`) is KILLED once this cap is hit; only a
                               # bounded head+tail is kept, so RAM stays bounded.

file_read:
  max_chars: 100000
```

### tool_output_compression

Deterministic (no-LLM) compression of a tool's output **before it reaches the
model**, to spend fewer context tokens on high-volume, low-signal output. This is
distinct from [`compression`](#compression) (which summarises the *conversation
history* when the window fills) and from `display.tool_output_preview_lines`
(scrollback-only). It runs at a single seam — every tool's output passes through
`Agent::ToolExecutor` — so a content **router** picks the strategy by what the
output *is*, not by which tool produced it:

| Output detected as | Strategy | Effect |
| --- | --- | --- |
| test / build / lint / shell logs (rspec, pytest, jest, cargo, npm, make, generic) | `LogCompressor` | keep every error/failure + the summary tally + context, drop passing/info noise (≈97% fewer tokens on a failing suite) |
| a **whole-file** source read (Ruby) | code `skeleton` | keep signatures, elide large method bodies behind a `read offset:/limit:` pointer |
| a unified diff (`git diff`, `diff`) | `DiffCompressor` | keep every `+`/`-` line and every file/hunk header; trim far unchanged context to ±N lines; collapse a generated/lock file to a one-line summary. A small/tight diff (the "show me the diff" case) passes through **byte-identical** via the saving guard. The human view is the tool's separate scrollback diff (`body`), which is **never** compressed |
| a **whole-output** JSON dump (`curl \| jq`, `kubectl get -o json`, `gh api`, `docker inspect`, `aws --output json`, MCP/custom-tool JSON) | `JsonCompressor` | an array of **uniform** objects folds **losslessly** to a schema header + one compact row per item (repeated key names emitted once); a large array whose fold is too thin falls back to lossy row selection where **error-bearing rows and statistical outliers always survive** and dropped rows collapse to an `{"_elided": N}` sentinel; a single large object elides only **big string values** (never drops a key). Detected **before** the log channel, so a JSON shell dump folds as a table and is never log-compressed. Small JSON passes through **byte-identical** via the saving guard |
| grep / search results (`path:line:`) | passthrough | **byte-identical** |
| short output | passthrough | unchanged |

```yaml
tool_output_compression:
  enabled: false              # MASTER switch — off ships by default; the whole
                              # router is bypassed when false. `rubino setup`
                              # offers to turn this (and logs.enabled) on.
  code:                       # whole-file source reads → skeleton
    strategy: skeleton        # only "skeleton" is implemented; any other value = passthrough
    min_lines: 150            # files shorter than this are never skeletonised
    keep_method_body_max_lines: 8  # bodies up to N lines are kept inline; larger ones are elided
    languages: [ruby]         # source languages to skeletonise (see note below); `rubino setup` lets you pick
  logs:
    enabled: false            # sub-gate: log compression only runs when BOTH this and the master are on
    min_lines: 40             # outputs shorter than this pass through unchanged
    max_total_lines: 100      # cap on kept lines
    max_errors: 10            # keep up to N errors/failures (first and last always kept)
    max_warnings: 5
    max_stack_traces: 3
    context_lines: 4          # lines of surrounding context kept around each failure
  diff:                       # unified diffs (git diff / diff) — model copy only
    context_lines: 3          # unchanged context kept on each side of a change; far context → `… N unchanged lines`
    min_lines: 40             # diffs shorter than this pass through unchanged ("show me the diff")
    min_saving: 0.25          # only apply when ≥25% smaller; else byte-identical passthrough
    generated_patterns:       # changed files matching these collapse to a one-line summary
      - "*.lock"
      - Gemfile.lock
      - package-lock.json
      - yarn.lock
      - pnpm-lock.yaml
      - composer.lock
      - "*.min.js"
      - "*.min.css"
      - dist/
      - build/
      - "*.snap"
      - vendor/
  json:                       # whole-output JSON dumps (kubectl/gh/docker/aws/jq)
    min_items: 8              # arrays with fewer items (and < min_lines) pass through unchanged
    min_lines: 40             # objects / text shorter than this pass through unchanged
    min_saving: 0.25          # only apply when ≥25% smaller; else byte-identical passthrough
    outlier_sigma: 3.0        # a numeric field > N σ from its column mean = a kept outlier row (lossy)
    max_string_chars: 400     # in a single object, string values longer than this collapse to `<elided N chars>` (key kept)
```

> **`code.languages`** (default `["ruby"]`) selects which source languages get
> whole-file skeletonisation; a read whose language isn't listed passes through
> verbatim, so removing a language disables compression for it. Values: `ruby`
> (built-in Prism parser, always available), `python` (stdlib `ast` via your
> `python3` — a no-op if `python3` isn't on PATH), and `javascript` /
> `typescript` / `tsx` (need the optional `tree_sitter_language_pack` gem — a
> no-op until it's installed). `rubino setup` offers a language picker and, if you
> choose JS/TS, asks before installing the parser gem.

> `diff` and `json` have **no** own `enabled` sub-gate (like `code`): they are
> active whenever the master flag is on, and the saving guard (`min_lines`/
> `min_items` + `min_saving`) is the real gate — small/tight diffs and small JSON
> the user wants to see stay verbatim automatically.

**Reversibility.** When the router compresses, the executor spills the *full
original* to `<home>/tool-results/<call_id>.txt` and the compressed output ends
with a passive pointer carrying the call's **id** (`… N line(s) hidden …
retrieve_output id=<id> only if a hidden line is specifically needed`). The model
recovers the original by calling the **`retrieve_output`** tool with that id —
registered **only** while compression is enabled (so the default registry/tool
count is unchanged). The pointer deliberately prints **no cat-able filesystem
path**: recovery is an id behind a dedicated tool (headroom-style), so a small
model can't `sed`/`grep`/`cat` a printed spill path and re-inflate the output the
compressor just shrank. If the spill failed the pointer says *full output
unavailable (spill failed)* with no id. **Fidelity:** a failure or summary line
is never dropped; only passing/info noise is.

**Per-call opt-out.** When the feature is on, `read` and `shell` advertise a
`compress` boolean parameter (default `true`); the model can pass `compress:false`
to receive the verbatim output for that one call (returned byte-identical).

**Telemetry.** Compression events are logged as `compression.applied` /
`compression.drill_in` / `compression.failed`. `compression.drill_in` is emitted
on every `retrieve_output` call (a deliberate recovery, carrying the `id`) and on
a `read`'s targeted offset-read into an elided `:code` skeleton body — so the
counter measures real recoveries and is **not** bypassable by a shell `sed`/
`grep`/`cat` (there is no path to cat). A strategy error always falls back to the
uncompressed text, so compression can never break a tool call.

### terminal

```yaml
terminal:
  backend: "local"
  cwd: null                # workspace root override; null = Dir.pwd
  file_sync_enabled: false
  file_sync_max_mb: 100
```

### approvals

```yaml
approvals:
  mode: "manual"               # manual | auto | skip
  auto_allow_readonly: true    # auto-allow provably read-only shell commands (ls, grep, git log, ...) without a prompt
  readonly_commands: []        # extra command names / leading-token prefixes (e.g. "docker ps") merged into the built-in read-only set
  wait_timeout_seconds: 900    # how long a run waits on a human decision before auto-DENYing (null = forever)
```

See [security.md](security.md#auto-allowed-read-only-commands) for the read-only parse rules (the hardline floor and `permissions: deny` always run first).

### permissions

Pattern-based rules (wildcard support):

```yaml
permissions:
  "git *": "allow"
  "shell rm -rf *": "deny"
  "shell bundle *": "allow"
  "write ~/.env": "deny"
  "read *": "allow"
```

Actions: `allow`, `ask`, `deny`

### attachments

SSRF guard + secure-by-default file-attachment policy. See [security.md](security.md).

The policy is enforced on **every** attachment surface: API/server run attachments and CLI image attachments (`-i`/`--image`, `@image` tokens, dropped paths, `/paste`) all pass the same classification (magic bytes win over extension) and `max_file_bytes` cap **before** anything is sent to a provider. A rejected CLI attachment is a clean one-line error, never a provider call.

```yaml
attachments:
  allowed_hosts: []          # hosts allowed for URL attachments (loopback always allowed; ALLOWED_FILE_URL_HOSTS env merged in)
  policy:
    max_file_bytes: 26214400         # 25 MB hard cap (checked before reading)
    inline_text_budget_bytes: 100000
    allow_kinds: [image, text, document, archive, binary]
    auto_extract_documents: false
    convert_max_elements: 50000            # decompression-bomb caps for the in-process document
    convert_max_decompressed_bytes: 5000000  # converters (a 100 KB .docx can expand to ~34 MB of
    convert_wall_clock_seconds: 15.0       # XML): a paragraph/row/page/slide count ceiling, an
                                           # accumulated decompressed-bytes ceiling, and a wall-clock
                                           # budget. On any cap it bails to the shell-extraction hint
    aux_vision_egress: true          # allow the `vision` tool to send an image to an EXTERNAL aux model (data egress; see below)
    archive: { max_entries: 2000, max_uncompressed_bytes: 268435456, max_entry_ratio: 100, max_total_ratio: 50, max_nesting_depth: 1 }
```

`aux_vision_egress` (default `true`) gates the **`vision` tool**: routing an
image to an external auxiliary vision model is data egress, so set it to `false`
to refuse — the tool then returns a clean error instead of sending the bytes
(#578). Independently, before any egress the tool **content-sniffs** the file
(magic bytes win over the extension, fail-closed): a path that isn't actually an
image is rejected, so a mislabelled or non-image file can't be smuggled to the
external host (#579).

### security

```yaml
security:
  confirm_policy: "dangerous_only"      # dangerous_only (default) | confirm_all
                                        # (the old require_confirmation_for_shell key was removed)
  command_allowlist: []                 # EMPTY by default — pre-approval is opt-in (empty = approve nothing).
                                        # Read-only commands (git status/diff, ls, grep, ...) already run
                                        # unprompted via the read-only auto-allow, so nothing needs seeding here.
                                        # Test/build runners (bundle exec rspec, rake, npm test) are deliberately
                                        # NOT auto-approvable: they load and run arbitrary project code.
  redact_secrets: true                  # ON by default (secure default): redact credential VALUES
                                        # (API keys, tokens, private keys, DB passwords, JWTs…) from
                                        # read/grep/shell output before it enters context, the
                                        # transcript, or the aux model. NOT a security boundary —
                                        # defense-in-depth. Set false only to work on the redactor itself.
  redaction: {}                         # pluggable redaction: "class" => custom redactor class, and/or
                                        # "custom_patterns" => [] extra regexes (added to the built-in set)
  website_blocklist:
    enabled: false
    domains: []
    shared_files: []
```

The hardline floor (catastrophic commands) and `permissions: deny` rules always run **before** any allow path, including `yolo`. See [security.md](security.md).

### doom_loop

Repeated-identical-tool-call guard (`DoomLoopDetector`). At the defaults it WARNS the model on the Nth identical call but still lets it through, so a legitimate retry of an idempotent read isn't hard-denied.

```yaml
doom_loop:
  hard_stop: false   # false (default) = surface a doom-loop WARNING but allow the call through;
                     #   true = restore the old block-at-threshold behaviour
  threshold: 5       # the Nth identical call trips the guard
```

### mcp

```yaml
mcp:
  servers:
    filesystem:
      transport: stdio
      command: "npx"
      args: ["@modelcontextprotocol/server-filesystem", "."]
      env:
        DEBUG: "1"
    remote_api:
      transport: streamable
      url: "https://mcp.example.com/api"
      headers:
        Authorization: "Bearer {env:MCP_TOKEN}"
      oauth:
        client_id: "{env:MCP_CLIENT_ID}"
        scope: "mcp:read mcp:write"
      timeout: 15000
```

Experimental. Configuring servers is the opt-in; `mcp.enabled: false` switches MCP off. The `oauth` hash is forwarded verbatim to `ruby_llm-mcp` — rubino implements no OAuth flow itself. See [mcp.md](mcp.md).

### skills

```yaml
skills:
  enabled: true
  auto_distill: true        # agentic post-turn skill distillation via the review fork; separate from `enabled`
  auto_distill_interval: 10 # throttle inter-turn distillation to ~every N turns (nil/<=1 = every turn)
  include_builtin: true     # also scan the gem-bundled skills/ catalogue (e.g. ruby-expert)
  paths:
    - ".rubino/skills"
    - "~/.rubino/skills"
```

The agent loads a skill's instructions on demand (`tools.skill` gates the loading
tool). With `skills.enabled` (default true) the agent also authors skills: the
warm-prefix review fork (`BackgroundReviewJob`, shared with memory extraction)
lets the agent agentically distil complex, repeatable runs into a new or updated
skill — inter-turn every `skills.auto_distill_interval` turns and once at session
end — and the agent can create/edit/patch/write_file/delete one on demand via the
`skill` tool's matching `action`. Setting `skills.enabled: false` turns off both
the distillation cost and the on-demand AUTHORING actions (`create`, `edit`,
`patch`, `write_file`, `delete` all refuse cleanly); `action: "load"` (reading an
existing skill) is unaffected — it is gated only by `tools.skill`, so the agent
can still use previously-authored skills with `skills.enabled: false`.

Skill activity is exported on `GET /v1/metrics` as two Prometheus counters:

- `skills_loaded_total` — number of times a skill body was successfully loaded via
  the `skill` tool (usage/adoption).
- `skills_created_total` — number of new skills created (the on-demand create tool
  and the registry's re-scan disk-diff both feed this).

A successful load emits the `SKILL_LOADED` event (`skill.loaded`); a creation emits
`SKILL_CREATED`. See **[docs/skills.md](skills.md)** for the full skill system,
including creation and the 3-level disclosure model.

### commands

```yaml
commands:
  paths:
    - ".rubino/commands"
    - "<RUBINO_HOME>/commands"  # sentinel; resolved against the home at read time, like database.path
  shell_injection_enabled: false  # true = allow !`shell` interpolation in command templates
```

### formatters

No formatters ship by default (`formatters: {}` — empty; this whole feature is inert until you add a key). Configure per-glob format commands, run after a `write`/`edit` tool call **successfully** touches a matching file:

```yaml
formatters:
  "*.rb": "rubocop -A --fail-level=fatal"
  "*.js": "prettier --write"
  "*.ts": "prettier --write"
  "*.py": "black"
```

Implemented by `Rubino::Formatters` (`lib/rubino/formatters.rb`), wired into both file-editing tools (`Tools::WriteTool` / `Tools::EditTool`, single-edit and `edits`-array forms alike):

- **Matching.** Each key is a glob (the same engine `permissions:` uses,
  `Security::PatternMatcher`) matched against the touched file's **basename**,
  not its full path — `"*.rb"` means "any `.rb` file", regardless of which
  directory it lives in. The **first** matching key in `formatters:`
  declaration order wins; only one formatter runs per file. A key mapped to a
  blank/whitespace command is skipped.
- **Argument contract.** The file's absolute path is appended as the command's
  **last shell argument** (shell-escaped) — exactly how you'd type
  `rubocop -A --fail-level=fatal path/to/file.rb` by hand. There is no
  `{file}`-style placeholder: every example above already expects the path as
  a trailing positional argument, so this is both the simplest contract and
  the one that matches real CLI usage.
- **Trust.** The command string comes from your own `config.yml` — the same
  trust tier as `permissions:` patterns and `mcp.servers` commands — so it is
  **not** approval-gated. It still runs through the identical OS write-jail
  every shell spawn goes through (`Tools::ShellTool.sandboxed_bash_argv` →
  `tools.sandbox`): a formatter is a trusted command, not a license to bypass
  the sandbox.
- **Execution.** Synchronous — the write/edit call blocks briefly (bounded by
  a 30s internal timeout; a hung/misconfigured command is TERM'd then KILL'd)
  so the on-disk content already reflects the formatted result the instant
  the tool call returns.
- **Failure handling.** A non-zero exit, a timeout, or a spawn error is
  best-effort: it **never** fails the write/edit call (the file itself was
  already written) — it only appends a one-line `[formatter] ...` note to the
  tool's output (plus a structured `formatters.run_failed` log line) and
  leaves the file exactly as the failed command left it.
- **Quiet on a no-op success.** When the formatter runs and changes nothing
  (the file was already properly formatted), nothing is appended — only a
  real reformat or a failure is worth telling the model/user about.
- **Read-tracker refresh.** When a formatter changes the file, the tool
  re-reads the real final bytes and refreshes the session's read-tracker with
  them, so the *next* edit's stale-read guard reflects what the formatter
  actually left on disk (not what the model originally sent) instead of
  spuriously tripping "changed on disk since last read".

### prompts

System-prompt layering. The defaults ship the built-in role prompts.

```yaml
prompts:
  preamble: null                 # block prepended after the role identity (customer context)
  environment:
    enabled: true                # inject an [Environment] block (date/OS/cwd/git/runtimes/PATH utilities)
    extra_utilities: []          # extra binaries to probe beyond the defaults
  prompt_cache: true             # emit Anthropic prompt-cache breakpoints (cache_control) on the
                                 # stable system prefix + last tool definition, so the fixed prompt
                                 # prefix is cached across turns (#311). Honored by anthropic-family
                                 # providers; others ignore it
```

> To fully replace a built-in role's prompt (and optionally its tools,
> permissions, or model too), use a file-based agent override instead — drop a
> `.md` file under `~/.rubino/agents/build.md` or `.rubino/agents/build.md` to
> replace the built-in "build" agent. See [agents.md](agents.md). There is
> deliberately no config-key equivalent.

### clarify / privacy

```yaml
clarify:
  timeout: 600          # seconds to wait for a clarification answer before proceeding with best judgement

privacy:
  redact_pii: false
```

### worktree

Isolates a session's file-touching work in a throwaway git worktree instead of your checked-out branch — so autonomous/`--yolo` runs ("let it work, I'll review the diff after") are reviewable and discardable via normal git, never touching your real working tree while the agent runs.

```yaml
worktree:
  enabled: false        # true = isolate this session in a linked git worktree
```

Resolved once, at session start, before the agent loop (or any tool call) runs — the same `setup_workspace_and_trust!` chokepoint that seeds `--add-dir` roots and the folder-trust gate. When `enabled: true` and the launch directory is inside a git repository:

1. Creates `<repo_root>/.worktrees/rubino-<id>` on a new `rubino/<id>` branch, branched from the repo's current `HEAD` — captured as a fixed commit SHA (not a moving ref), so a commit landing in your real checkout later in the session can't shift the base out from under the exit-time "any commits?" check. Branching from local `HEAD` (no `fetch`) is deliberate: the worktree is created inside the very checkout you're already sitting in, so local `HEAD` is the freshest ref available — unlike a tool that ships its own separately-updated clone, there's no staleness to correct for.
2. Appends `.worktrees/` to the repo's `.gitignore` if it isn't already there.
3. Redirects the session's effective workspace root (`Workspace.primary_root` — the same seam the interactive shell's `cd` already redirects through) at the new worktree path. Every read/write/edit/grep/glob/shell call for the rest of the session resolves against the isolated worktree, not the original checkout.
4. Appends a short note to the assembled system prompt (the existing `prompts.preamble` layer — no new prompt-injection mechanism) telling the model it's working in an isolated worktree and must commit its work there before the session ends.

On a clean session exit:

- **No commits** ahead of the captured base commit ⇒ the worktree and its branch are removed silently — nothing of value was created. Uncommitted/untracked files alone don't count; only commits survive.
- **One or more commits** ⇒ both are **kept**, and rubino prints the exact path, branch name, and the `git` commands to review/diff/merge/discard it. **rubino never merges, pushes, or opens a pull request on this branch itself** — a human reviews and merges (or discards) it manually via normal `git` after the session ends.

A launch directory that isn't a git repository — or any other git failure (an empty/unborn repo with no commit yet, `git worktree add` refusing) — degrades gracefully: the session still starts, unredirected, exactly as if `worktree.enabled` were `false`, with a one-line notice explaining why.

Not yet implemented (deliberately deferred, not required for the core create → redirect → clean-or-keep lifecycle above): locking the worktree for the session's duration (`git worktree lock`) and an age-based pruner for orphaned worktrees left behind by a killed (`kill -9`) process. A leftover, un-pruned `.worktrees/rubino-*` directory from a crash is an accepted (disk-only) cost — it never corrupts your real checkout, since nothing in this feature ever writes to it.

### otel

Opt-in OpenTelemetry tracing. Requires the optional `opentelemetry-sdk` and `opentelemetry-exporter-otlp` gems — see [observability.md](observability.md) for the span catalog, privacy model, and a quick-start with a local collector.

```yaml
otel:
  enabled: false             # master switch (needs the optional OTel gems installed)
  endpoint: null             # collector base URL or full /v1/traces URL; null = OTEL_EXPORTER_OTLP_* env vars, then http://localhost:4318
  headers: {}                # extra exporter headers, e.g. Authorization: "Bearer ${OTEL_TOKEN}"
  environment: null          # stamped as deployment.environment.name (dev/staging/prod)
  capture_content: false     # PRIVACY GATE: export message/tool text (redacted + truncated) — default OFF
  resource_attributes: {}    # extra key/value resource attributes on every span
```

### agents (planned — not yet read)

> **Status: planned, has no effect today.** The `agents:` key is reserved but is
> **not read** by the registry, so declaring custom agents in `config.yml` does
> nothing yet. Primary-agent *switching* among the built-in agents already ships
> (`/agent`, `/<name>`, Tab — see [agents.md](agents.md#primary-agent-switching));
> what is not wired is authoring NEW agents from config. To register a custom
> agent today, use `AgentRegistry#register` programmatically (see
> [agents.md](agents.md#custom-agents-via-code)).

The intended shape, once config-authored agents land:

```yaml
agents:
  security:
    type: subagent
    model: "anthropic/claude-sonnet-4-20250514"
    description: "Security-focused code review"
    tools: [read, grep, glob]
    mcp_servers: []
```

### api

The API server's listen port and bind host come from the CLI, not config:
`rubino server --port <n>` (or `RUBINO_API_PORT`, default `4820`) and `--host`
(or `RUBINO_API_HOST`). The bearer token is `RUBINO_API_KEY`. The `api` block
configures payload caps, rate limiting, and the public-bind gate:

```yaml
api:
  max_body_bytes: 5242880        # 5 MB cap on JSON request bodies (413 past this)
  max_upload_bytes: 52428800     # 50 MB cap on multipart uploads
  rate_limit_enabled: true
  rate_limit_unauth_per_minute: 60
  rate_limit_auth_per_minute: 600
  allow_public_bind: false       # gate for a non-loopback bind (see below)
```

`allow_public_bind` is **false by default (safe)**. The API can execute shell
tools, so binding it to a non-loopback address (`--host 0.0.0.0`,
`RUBINO_API_HOST` set to anything other than `127.0.0.1` / `::1` / `localhost`)
publishes a remote-code-execution surface to the network — and with TLS off the
bearer token and all traffic travel in cleartext. While this is `false`, the
server **refuses to boot** on a non-loopback host with an actionable error.
Loopback binds (the default) are unaffected and need no opt-in.

To deliberately expose the listener, set `allow_public_bind: true`. The server
then boots on the routable host but prints a one-time exposure **WARNING** at
startup. When you opt in, enable TLS (`RUBINO_TLS=1`) and a strong
`RUBINO_API_KEY`, and prefer a reverse proxy over a direct bind.

---

## Environment Variables

### Provider keys

| Variable | Purpose |
|----------|---------|
| `MINIMAX_API_KEY` | MiniMax API key |
| `OPENAI_API_KEY` | OpenAI key (also the fallback for `openai_compatible` gateways) |
| `ANTHROPIC_API_KEY` | Anthropic key (also the fallback for `anthropic_compatible` gateways) |
| `GEMINI_API_KEY` / `GOOGLE_API_KEY` | Google Gemini key |
| `BEDROCK_API_KEY` | AWS Bedrock bearer key |

### Agent runtime

| Variable | Purpose |
|----------|---------|
| `RUBINO_HOME` | Relocate the home dir; config, `.env`, and the database all follow it |
| `RUBINO_ALLOW_FAKE` | `1` to allow the fake provider in `chat`/`server` (dev only) |
| `RUBINO_HYPERLINKS` | Toggle terminal hyperlink output |
| `RUBINO_LOG_LEVEL` / `RUBINO_LOG_FORMAT` | Logging verbosity / format |

### HTTP API server

| Variable | Purpose |
|----------|---------|
| `RUBINO_API_KEY` | Bearer token required on every API request |
| `RUBINO_API_HOST` / `RUBINO_API_PORT` | Bind interface / port |
| `RUBINO_ENCRYPTION_KEY` | Required to encrypt OAuth tokens at rest |
| `RUBINO_TLS` | `1` to serve the API over a self-signed, client-pinned cert |
| `RUBINO_WEBHOOK_URL` / `RUBINO_WEBHOOK_SECRET` | Outbound webhook target + signing secret |

### Tools & network

| Variable | Purpose |
|----------|---------|
| `GITHUB_TOKEN` | GitHub token inherited by the `shell` tool's environment (used by `git`/`gh`); there is no dedicated `github` tool |
| `TAVILY_API_KEY` | Tavily search key for the `web_search` tool |
| `SEARXNG_URL` | SearXNG instance URL for the `web_search` tool |
| `ALLOWED_FILE_URL_HOSTS` | Comma-separated extra hosts for URL attachments (merged with `attachments.allowed_hosts`) |
| `SUDO_PASSWORD` | When set, relaxes the `sudo -S` hardline guard |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | Standard network proxy (full HTTP/HTTPS/SOCKS support) |
| `SSL_CERT_FILE` | Custom CA certificate bundle |

> There is no `RUBINO_PROXY_URL`; the agent uses the standard `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` variables (and SOCKS) for outbound network proxying.
