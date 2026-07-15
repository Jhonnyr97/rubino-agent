# rubino

A coding & automation **agent** — small, self-contained, and built to run *where the work is*: directly on your machine or inside a VM. You drop it onto a box and it works there, reachable over a CLI and an HTTP API. It is not a heavy framework; it's a lightweight agent with persistent memory, sessions, and context compaction. Built on [ruby_llm](https://github.com/crmne/ruby_llm).

## Why rubino

- **Runs where the work is** — a single gem on the machine (or VM) that holds the code, not a remote service you pipe files to.
- **Persistent memory** — a tiny SQLite fact store that learns about you and the project across sessions.
- **Context compaction** — automatic compression with session lineage when the conversation outgrows the window.
- **CLI *and* HTTP API** — an interactive terminal session for humans, a bearer-protected JSON + SSE API for programs.
- **Real tools, gated** — read/write/edit, shell, ruby, grep/glob, vision, and more (git, GitHub, and tests run through the hardened shell), behind an approval model with a non-bypassable hardline floor.
- **Built on ruby_llm** — provider-agnostic: MiniMax, OpenAI, Anthropic, Gemini, or an OpenAI-compatible gateway.

## Cache-friendly compaction (measured)

A long agent session only stays cheap if the cached prompt prefix survives
compaction. rubino is built so that when the conversation is compressed into a
summary, the summary lands *after* the cached head (system + tools + stable
history) — so the provider's prompt cache keeps **hitting** the head instead of
re-encoding it cold every time the session is compacted.

Measured with the model held fixed (local oMLX `Qwen3.6-35B-A3B`,
Anthropic-style `cache_control`) on a 25-turn coding session that triggers
compaction **9 times**:

| metric | rubino |
|---|---|
| cached prefix retained right after each compaction | **44–94%** (survives — never resets to 0) |
| cumulative cache-read over the whole session | **88%** |
| prefix byte-stability across turns | **0.95** |
| task solved through all 9 compactions | **10/10** hidden tests, 0 wasted work |

Holding the model fixed isolates the **engine** — any difference is the
scaffolding (prompt assembly, where the compaction summary is placed, cache
breakpoints), not the model. This is a single model and a single scenario:
indicative of the design, not a leaderboard. The harness lives in a separate
benchmark project.

## Tool-output compression (measured)

Test logs, diffs and large command dumps are mostly noise. rubino can route
each tool output through a **deterministic (no-ML)** compressor that keeps the
signal and drops the rest — opt-in (`tool_output_compression`), with a
byte-identical passthrough for anything already small and a `retrieve_output`
pointer back to the full text. Token-honest: counts are the **exact**
`prompt_tokens` reported by the server (local oMLX `Qwen3.6-35B-A3B`), not
chars/4 estimates.

| tool output | reduction | fidelity (verified) |
|---|---:|---|
| rspec full suite (21 failures, ~8k lines) | **97%** | all 21 failures + the tally kept |
| `git log --stat` / `ls -R` | **94%** | boundary/keyword lines kept |
| large source diff (9 files) | **42%** | all 575 ± lines, 13 hunks, 9 headers |
| `package-lock.json` diff (60 bumps) | **99%** | file header + summary (body elided) |
| whole-file Ruby read → skeleton | **27%** | signatures + structure kept |
| JSON (kubectl / docker / gh, uniform rows) | **40–88%** | error rows + outliers always kept |
| rubocop (already signal-dense) | 11% | floor — every offense kept |

End-to-end A/B on real edit tasks: **12/12 tasks passed with compression ON and
OFF** — it never broke a task, and every forced-failure run still recovered the
single failing line out of a long log. Routing is verified (each output goes to
the right strategy) and small inputs pass through **byte-identical**.

## Install

One line, Linux and macOS (x86_64 / arm64). Installs a compatible Ruby, then the gem — all in user space, no sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/Jhonnyr97/rubino-agent/main/install.sh | bash
```

The installer supports **three** methods for getting a compatible Ruby + the gem:

- **`rv`** ([`rv`](https://github.com/spinel-coop/rv)) — fetches a precompiled Ruby into user space.
- **Homebrew** (`brew install ruby`) — offered on **macOS** when [Homebrew](https://brew.sh) is present.
- **`mise`** ([mise](https://mise.jdx.dev)) — a polyglot tool manager; installs `rubino` via its `gem:` backend and pins the latest published gem version.

On **macOS** (interactive) you're asked to pick Homebrew / `rv` / `mise`; on **Linux** (interactive) you pick `rv` / `mise` (Homebrew is offered only if `brew` is already on PATH). Skip the prompt with `RUBINO_INSTALL_METHOD=brew`, `=rv`, or `=mise`. For the **mise** method, `RUBINO_INSTALL_SCOPE=global` (default, user-wide `~/.config/mise/config.toml`) or `=local` (this directory only, `./mise.toml`) chooses the scope.

On **Debian 12 / old-glibc** systems `rv` would install a musl Ruby this glibc box can't execute; the installer detects that and **steers you from `rv` to `mise`** (precompiled, glibc-correct) so you don't land on a broken `rubino`.

> **Review before you pipe.** Piping a script into your shell runs whatever it contains. Read it first:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/Jhonnyr97/rubino-agent/main/install.sh -o install.sh
> less install.sh && bash install.sh
> ```

The installer is idempotent — safe to re-run. It **persists the activation / `PATH` line to your shell rc** (`.zshrc` / `.bashrc` / `.profile`) and then runs a **fresh-shell verification gate** — it opens a clean login shell and fails loudly if `rubino` isn't on `PATH` there, instead of merely printing a hint you might miss. Opt out of any rc modification with `RUBINO_NO_MODIFY_RC=1` (the installer then prints the line for you to add yourself).

**Manual install** (if you'd rather not pipe, or already manage Ruby yourself):

```bash
# With rv (https://rv.dev):
curl -LsSf https://rv.dev/install | sh
rv ruby install 3.3.3
rv run --ruby 3.3.3 gem install rubino-agent

# Or with any Ruby >= 3.1 already on your PATH:
gem install rubino-agent
```

## Quick Start

```bash
rubino setup        # guided first-run: pick a provider, paste a key
rubino chat         # start chatting; ask "what does this project do?"
```

`rubino setup` runs an interactive wizard that picks a provider/model and stores your API key — no hand-editing of YAML to get a first answer. If you skip the wizard, a bare `rubino chat` from a fresh home launches it for you before the first message.

New here? Read **[docs/getting-started.md](docs/getting-started.md)** — install → setup → first working message.

In development:

```bash
git clone https://github.com/Jhonnyr97/rubino-agent.git
cd rubino-agent
bundle install
bundle exec rubino setup
bundle exec rubino chat
```

## Requirements

- Ruby >= 3.1
- SQLite3
- An LLM provider API key (MiniMax, OpenAI, Anthropic, or Google) — or any OpenAI-compatible gateway.

## Essential commands

| Command | What it does |
|---|---|
| `rubino setup` | Guided first-run: provider/model/key, config + database |
| `rubino chat` | Interactive session (bare `chat` auto-resumes your last session) |
| `rubino chat --new` | Start a fresh session instead of resuming |
| `rubino prompt "..."` | One-shot, non-interactive (alias for `chat -q`) |
| `rubino server` | Start the JSON API + SSE server |
| `rubino doctor` | Check config, credentials, and database health |
| `rubino tools` | List tools and their enabled/disabled state |
| `rubino memory list` | Inspect stored memories (uses the active backend) |
| `rubino version` | Print the version |
| `rubino update` | Update to the latest published version via RubyGems |

`rubino update` runs `gem update rubino-agent` under the active interpreter (multi-Ruby safe); for a source/dev checkout it points you back at the installer instead. On interactive boot rubino shows a single dim line when a newer version is available (`▸ rubino vX.Y available — run \`rubino update\``). The check is cached and refreshed out-of-band (once / 24h, short timeout), so it never slows startup and is silent offline. Set `RUBINO_NO_UPDATE_CHECK=1` to disable it (it is also off when not a TTY or under `CI`). It prints nothing until the gem is actually published. See **[docs/commands.md](docs/commands.md)**.

Inside a chat, type `/help` for the slash commands (`/status`, `/sessions`, `/memory`, `/agents`, `/skills`, `/mode`, `/commands`, `/new`, …). The full reference is **[docs/commands.md](docs/commands.md)**.

## Configuration

Configuration lives in `~/.rubino/config.yml` (created by `rubino setup`); secrets go in `~/.rubino/.env`. Both follow `RUBINO_HOME` if set. A representative slice (defaults shown):

```yaml
model:
  default: "openai/gpt-4.1"   # the shipped default — see the note below
  provider: "auto"            # auto | openai | anthropic | bedrock | gemini | minimax | gateway
  temperature: null           # inherit the provider default (no temperature is sent)

agent:
  max_turns: 90
  max_tool_iterations: 90

memory:
  enabled: true
  backend: "sqlite"           # SQLite FTS5 + graph-lite recall (default)
  auto_extract: true

compression:
  enabled: true
  threshold: 0.50

jobs:
  mode: "inline"              # inline | manual | worker

tools:
  workspace_strict: true      # sandbox write/edit/delete to the workspace
  shell: true                 # ON by default; every command is still approval-gated
  ruby: true
  web: true                   # ON by default (keyless DuckDuckGo backend); gates BOTH web_fetch and web_search
  memory: true
```

> **Heads-up on the default model.** The shipped `model.default` is `openai/gpt-4.1`, which ruby_llm's registry resolves to **OpenRouter** — so a first run with no OpenAI/OpenRouter key fails fast with guidance instead of hanging. Run `rubino setup` (the wizard defaults to OpenAI gpt-4.1) or set your provider/key explicitly. See **[docs/models-and-keys.md](docs/models-and-keys.md)**.

Full reference (every key, env vars, precedence): **[docs/configuration.md](docs/configuration.md)**.

## Documentation

- **[Getting started](docs/getting-started.md)** — install → setup → first message
- **[Models & keys](docs/models-and-keys.md)** — which provider/model/key, per-provider setup blocks
- **[Commands](docs/commands.md)** — CLI subcommands + slash-command reference
- **[Configuration](docs/configuration.md)** — full config + env vars + precedence
- **[Tools](docs/tools.md)** — the built-in tool set and approval behavior
- **[Skills](docs/skills.md)** — reusable instruction packs, the 3-level disclosure, and `SKILL_LOADED` observability
- **[Memory](docs/memory.md)** — the SQLite memory backend
- **[Markdown extensions](docs/markdown-extensions.md)** — file-based agents, skills, commands, and rules (portable `.md` packs; also reads `~/.claude/…`)
- **[Security](docs/security.md)** — approval model, hardline floor, TLS
- **[Troubleshooting](docs/troubleshooting.md)** — keyed on the exact error strings
- **[HTTP API](docs/api/v1.md)** · **[Jobs & cron](docs/jobs.md)** · **[OAuth providers](docs/oauth-providers.md)** · **[Architecture](docs/architecture.md)**
- **[Contributing](CONTRIBUTING.md)** · **[Changelog](CHANGELOG.md)**

## Built-in tools

The agent ships **22 built-in tools** (the set `rubino tools` lists): `vision`, `read`, `write`, `edit`, `grep`, `glob`, `shell`, `shell_manage`, `ruby`, `web_fetch`, `web_search`, `question`, `todowrite`, `memory`, `session_search`, `attach_file`, `skill`, `task`, `task_result`, `task_stop`, `steer`, `probe`. `read` reads both text files and documents (PDF/office/etc., converted in-process). Several tools share one config gate — `web_fetch` and `web_search` share `tools.web` (on by default via the keyless DuckDuckGo backend; it degrades gracefully when no search backend is reachable), the delegation family (`task`, `task_result`, `task_stop`, `steer`, `probe`) shares `tools.task`. Each tool is gated by a `tools.<key>` config flag (opt-out) and the approval model. See **[docs/tools.md](docs/tools.md)**.

## Skills

Skills are reusable instruction packs (a `SKILL.md` plus optional bundled reference files) that the agent pulls into context only when relevant — it sees a short index of available skills up front (Level 1), loads a skill's full body on demand (Level 2, which emits the `SKILL_LOADED` signal), and reads bundled references when needed (Level 3). They live in `.rubino/skills` / `~/.rubino/skills`, are gated by `tools.skill`, and expose usage/creation metrics. See **[docs/skills.md](docs/skills.md)**.

## Fake LLM provider

rubino ships a built-in **fake LLM provider** for tests, demos, and integration harnesses. Unlike a mocked adapter, the fake provider plugs into the *real* `Agent::Loop`, the real `ToolExecutor`, the real approvals/clarifications pipeline, and the real SSE stream — scenarios fake only what an LLM would produce (content / thinking chunks and `tool_call` requests). Downstream consumers hit the same surface they would against OpenAI/Anthropic, at zero token cost.

```yaml
model:
  default: "fake/happy-path"

providers:
  fake:
    scenarios_dir: "~/.rubino/scenarios"  # optional; defaults to built-in
```

Any `model_id` starting with `fake` is auto-routed to the fake provider. Because it can short-circuit tool decisions, it is **disabled by default** in `server` and `chat` — set `RUBINO_ALLOW_FAKE=1` to opt in. Production deployments must never set this.

## HTTP API

Start the bearer-protected JSON API server:

```bash
export RUBINO_API_KEY="$(openssl rand -hex 32)"
export RUBINO_ENCRYPTION_KEY="$(openssl rand -base64 32)"   # required for OAuth routes
rubino server --port 4820
```

Every request carries `Authorization: Bearer <RUBINO_API_KEY>` except `GET /v1/health` and `GET /v1/metrics`. The server binds `127.0.0.1` by default — pass `--host 0.0.0.0` (or set `RUBINO_API_HOST`) to expose it, and only do so behind TLS or a trusted segment. For a remote HTTP client the API can serve over a self-signed cert the client pins (`RUBINO_TLS=1`; read it with `rubino tls-cert`).

Full request/response shapes, the error envelope, and SSE replay are in **[docs/api/v1.md](docs/api/v1.md)**.

## Planned / on the roadmap

These are designed-in but not fully wired yet — don't depend on them in production:

- **MCP Support** — connect to Model Context Protocol servers via [ruby_llm-mcp](https://github.com/patvice/ruby_llm-mcp). Experimental: stdio servers are wired end-to-end; `sse`/`streamable` are less battle-tested and OAuth isn't implemented on the rubino side ([docs/mcp.md](docs/mcp.md)).

Multi-agent already ships (background subagents via the `task` tool + primary-agent switching via `/agent`, a bare `/<name>`, and Tab); agents are reached on the `/` channel — there is no `@mention` agent routing (`@` is the workspace file picker). See [docs/agents.md](docs/agents.md).

## Development

```bash
bundle install
bundle exec rspec               # run tests (sequential, with coverage)
bundle exec rake parallel:spec  # run tests across all CPU cores
bundle exec rubino doctor   # verify setup
```

See **[CONTRIBUTING.md](CONTRIBUTING.md)** for the full dev/test/release flow.

## License

[MIT](LICENSE).
