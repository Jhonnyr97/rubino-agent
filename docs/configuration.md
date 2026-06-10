# Configuration Reference

All values below are checked against `lib/rubino/config/defaults.rb` (`MODULE_DEFAULTS`) — the single source of truth. Only keys that ship a default are shown with one; everything else is opt-in.

## File Locations

- **User config:** `~/.rubino/config.yml` (created by `rubino setup`)
- **Project config:** `.rubino/config.yml` (overrides user config)
- **Secrets:** `~/.rubino/.env`
- **Database:** `~/.rubino/rubino.sqlite3`

> **`RUBINO_HOME` relocates everything.** When set, the home directory, `config.yml`, `.env`, and the database all follow it (the `database.path` default is a sentinel resolved at read time against the resolved home — issue #96). The CLI and the API server share one resolver, so they never disagree about where state lives.

## Precedence (highest to lowest)

1. Environment variables (`RUBINO_*`)
2. Project-local `.rubino/config.yml`
3. User global `~/.rubino/config.yml`
4. Built-in defaults

## Substitutions

Use in any string value:
- `{env:VAR_NAME}` or `${VAR_NAME}` — inserts an environment variable
- `{file:path/to/file}` — inserts file contents

---

## Full Config Reference

### model

```yaml
model:
  default: "openai/gpt-4.1"     # Model identifier (NOTE: resolves to OpenRouter — see models-and-keys.md)
  provider: "auto"              # auto | openai | anthropic | bedrock | gemini | minimax | gateway
  context_length: null          # Override context window (null = use model default)
  temperature: 0.3              # Generation temperature
  max_tokens: null              # Max output tokens (anthropic-family path); null = adapter default (16384)
  thinking_budget: null         # LEGACY — superseded by thinking.effort (below); null = adapter default (8000), 0 disables
  max_tokens_text_headroom: 4096  # Visible-output headroom reserved on top of the thinking budget
  supports_vision: null         # null = auto-detect from model id; true/false to override
```

> The shipped default `openai/gpt-4.1` resolves to OpenRouter in ruby_llm's registry. See [models-and-keys.md](models-and-keys.md) for the per-provider blocks and the fail-fast behavior.

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
```

Per-provider you may also set `api_key`, and for custom gateways `anthropic_compatible: true` (MiniMax) or `openai_compatible: true`. See [models-and-keys.md](models-and-keys.md).

### auxiliary

```yaml
auxiliary:
  compression:
    provider: "main"     # "main" uses default model
    model: ""            # Specific model for compression
    base_url: null
    timeout: 120
  approval:
    provider: "main"
    model: ""
    base_url: null
    timeout: 30
  vision:                # `vision` tool delegates here so a text-only primary can "see"
    provider: "main"
    model: ""            # "auto-vision" lets an OpenAI-compatible gateway pick
    base_url: null
    timeout: 120
  summarize:             # `summarize_file` tool map-reduces big files out-of-context here
    provider: "main"
    model: ""
    base_url: null
    timeout: 300
```

### agent

```yaml
agent:
  max_turns: 90                              # Max turns per session
  max_tool_iterations: 8                     # Max consecutive tool calls
  max_turn_seconds: 120                      # Timeout per turn
  api_max_retries: 5                         # LLM API retry count (exp backoff)
  api_retry_backoff_cap_seconds: 16          # Max per-retry backoff draw
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

The legacy `display.show_reasoning` boolean maps in only when `display.reasoning` is unset (`true`→full, `false`→hidden); `model.thinking_budget` is likewise superseded by `thinking.effort`.

### streaming

```yaml
display:
  streaming: true
  reasoning: collapsed   # see "reasoning & thinking" above
  show_reasoning: true   # LEGACY — superseded by display.reasoning
  language: "en"
  runtime_footer: { enabled: false }
  interim_assistant_messages: false

streaming:
  enabled: true
  transport: "off"
  edit_interval: 0.3
  buffer_threshold: 40
  cursor: " ▉"

context:
  engine: "compressor"
  max_tokens: null
```

### compression

```yaml
compression:
  enabled: true
  threshold: 0.50              # Trigger at 50% of context window
  gateway_threshold: 0.85      # Critical threshold
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
  backend: "sqlite"          # tiny-Zep FTS5/BM25 + graph-lite recall (default). "default" = legacy non-ranked store
  auto_extract: true
  auto_save: true
  user_profile_enabled: true
  project_context_enabled: true
  memory_char_limit: 2200    # injection budget at RETRIEVAL time
  user_char_limit: 1375
  ingest_char_limit: null    # cap on the live set at STORE time (null = unbounded)
  sqlite:
    vector: false            # opt-in sqlite-vec/embedding KNN on top of FTS5 (needs RubyLLM.embed)
    graph: true              # graph-lite 1-hop entity/edge blend
```

See [memory.md](memory.md) for the backend internals.

### jobs

```yaml
jobs:
  mode: "inline"              # inline | manual | worker
  poll_interval: 2            # Worker poll interval (seconds)
  max_attempts: 3
  retry_backoff_seconds: 30
```

### tools

```yaml
tools:
  workspace_strict: true  # Sandbox write/edit/delete to workspace_root; false = any reachable path
  git: true
  shell: true             # ON by default (the agent ships to run inside an isolated VM);
                          # every command is still gated by security.require_confirmation_for_shell
  ruby: true
  web: false              # Gates BOTH the webfetch and websearch tools
  memory: true
```

Each tool declares its own `tools.<key>` gate (`Tools::Base#config_key`). A key
absent from config means the tool is enabled (opt-out model); only an explicit
`false` disables it. So the keys above are the ones that ship a default — file
tools (`read`/`write`/`edit`/`multi_edit`/`grep`/`glob`/`apply_patch`),
`github`, and the rest are on by default and don't need a config entry. Note
both web tools share a single gate: `tools.web` controls `webfetch` **and**
`websearch` (there is no `tools.webfetch` / `tools.websearch`).

### tool_output

```yaml
tool_output:
  max_bytes: 50000
  max_lines: 2000
  max_line_length: 2000

file_read:
  max_chars: 100000
```

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
  wait_timeout_seconds: 900    # how long a run waits on a human decision before auto-DENYing (null = forever)
```

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
    aux_vision_egress: true
    archive: { max_entries: 2000, max_uncompressed_bytes: 268435456, max_entry_ratio: 100, max_total_ratio: 50, max_nesting_depth: 1 }
```

### security

```yaml
security:
  # confirm_policy: "confirm_all"      # confirm_all (default) | dangerous_only; derived from the alias below when absent
  require_confirmation_for_shell: true  # legacy alias for confirm_policy; true => confirm_all
  command_allowlist:                    # prefix-matched commands pre-approved (empty = approve nothing)
    - "git status"
    - "git diff"
    - "bundle exec rspec"
  website_blocklist:
    enabled: false
    domains: []
    shared_files: []
```

The hardline floor (catastrophic commands) and `permissions: deny` rules always run **before** any allow path, including `yolo`. See [security.md](security.md).

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
  paths:
    - ".rubino/skills"
    - "~/.rubino/skills"
```

The agent loads a skill's instructions on demand (`tools.skill` gates the loading
tool). With `skills.enabled` (default true) the agent also creates skills: the
deterministic post-turn `DistillSkillJob` distils complex, repeatable runs into a
new skill (gated on a tool-count threshold, default 5 — set
`RA_DISTILL_TOOL_THRESHOLD` to tune), and the agent can author one on demand via
`skill(action: "create", ...)`. Setting `skills.enabled: false` turns off both
the distillation cost and the create affordance.

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
    - "~/.rubino/commands"
  shell_injection_enabled: false  # true = allow !`shell` interpolation in command templates
```

### formatters

```yaml
formatters:
  "*.rb": "rubocop -A --fail-level=fatal"
  "*.js": "prettier --write"
  "*.ts": "prettier --write"
  "*.py": "black"
```

### agents

Custom agent definitions:

```yaml
agents:
  security:
    type: subagent
    model: "anthropic/claude-sonnet-4-20250514"
    description: "Security-focused code review"
    tools: [read, grep, glob]
    mcp_servers: []
```

### prompts

System-prompt layering. The defaults ship the built-in role prompts.

```yaml
prompts:
  preamble: null                 # block prepended after the role identity (customer context)
  environment:
    enabled: true                # inject an [Environment] block (date/OS/cwd/git/runtimes/PATH utilities)
    extra_utilities: []          # extra binaries to probe beyond the defaults
  overrides: {}                  # prompts.overrides.<role> fully replaces a built-in role prompt
```

### clarify / worktree / privacy / quick_commands

```yaml
clarify:
  timeout: 120          # seconds to wait for a clarification answer

worktree:
  enabled: false        # run in a git worktree

privacy:
  redact_pii: false

quick_commands: {}      # named one-line shortcuts
```

### formatters

```yaml
formatters:
  "*.rb": "rubocop -A --fail-level=fatal"
  "*.js": "prettier --write"
  "*.ts": "prettier --write"
  "*.py": "black"
```

### agents (planned)

Custom agent definitions (multi-agent routing is not fully wired yet — see [agents.md](agents.md)):

```yaml
agents:
  security:
    type: subagent
    model: "anthropic/claude-sonnet-4-20250514"
    description: "Security-focused code review"
    tools: [read, grep, glob]
    mcp_servers: []
```

### server / api

```yaml
server:
  port: 4820
  auth: false

api:
  max_body_bytes: 5242880        # 5 MB cap on JSON request bodies (413 past this)
  max_upload_bytes: 52428800     # 50 MB cap on multipart uploads
  rate_limit_enabled: true
  rate_limit_unauth_per_minute: 60
  rate_limit_auth_per_minute: 600
```

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
| `GITHUB_TOKEN` | GitHub access token for the `github` tool |
| `TAVILY_API_KEY` | Tavily search key for `websearch` |
| `SEARXNG_URL` | SearXNG instance URL for `websearch` |
| `ALLOWED_FILE_URL_HOSTS` | Comma-separated extra hosts for URL attachments (merged with `attachments.allowed_hosts`) |
| `SUDO_PASSWORD` | When set, relaxes the `sudo -S` hardline guard |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | Standard network proxy (full HTTP/HTTPS/SOCKS support) |
| `SSL_CERT_FILE` | Custom CA certificate bundle |

> There is no `RUBINO_PROXY_URL`; the agent uses the standard `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` variables (and SOCKS) for outbound network proxying.
