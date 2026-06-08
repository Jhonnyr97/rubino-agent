# rubino

A coding & automation **agent** — small, self-contained, and built to run *where the work is*: directly on your machine or inside a VM. You drop it onto a box and it works there, reachable over a CLI and an HTTP API. It is not a heavy framework; it's a lightweight agent with persistent memory, sessions, and context compaction. Built on [ruby_llm](https://github.com/crmne/ruby_llm).

## Why rubino

- **Runs where the work is** — a single gem on the machine (or VM) that holds the code, not a remote service you pipe files to.
- **Persistent memory** — a tiny SQLite "Zep"-style fact store that learns about you and the project across sessions.
- **Context compaction** — automatic compression with session lineage when the conversation outgrows the window.
- **CLI *and* HTTP API** — an interactive terminal session for humans, a bearer-protected JSON + SSE API for programs.
- **Real tools, gated** — read/write/edit, shell, ruby, git/github, grep/glob, a structured test runner, vision, and more, behind an approval model with a non-bypassable hardline floor.
- **Built on ruby_llm** — provider-agnostic: MiniMax, OpenAI, Anthropic, Gemini, or an OpenAI-compatible gateway.

## Install

One line, Linux and macOS (x86_64 / arm64). Installs a compatible Ruby, then the gem — all in user space, no sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/Jhonnyr97/rubino-agent/main/install.sh | bash
```

On **Linux** the installer fetches a precompiled Ruby via [`rv`](https://github.com/spinel-coop/rv). On **macOS**, if [Homebrew](https://brew.sh) is present it asks whether to use Homebrew (`brew install ruby`) or `rv`; without Homebrew it uses `rv` directly. Skip the prompt with `RUBINO_INSTALL_METHOD=brew` or `=rv`.

> **Review before you pipe.** Piping a script into your shell runs whatever it contains. Read it first:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/Jhonnyr97/rubino-agent/main/install.sh -o install.sh
> less install.sh && bash install.sh
> ```

The installer is idempotent — safe to re-run — and prints the exact `PATH` line for the `rubino` executable plus the next step.

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
- An LLM provider API key (MiniMax, OpenAI, Anthropic, or Google) — or run behind the rubino-ui proxy.

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

Inside a chat, type `/help` for the slash commands (`/status`, `/sessions`, `/memory`, `/agents`, `/skills`, `/mode`, `/commands`, `/new`, …). The full reference is **[docs/commands.md](docs/commands.md)**.

## Configuration

Configuration lives in `~/.rubino/config.yml` (created by `rubino setup`); secrets go in `~/.rubino/.env`. Both follow `RUBINO_HOME` if set. A representative slice (defaults shown):

```yaml
model:
  default: "openai/gpt-4.1"   # the shipped default — see the note below
  provider: "auto"            # auto | openai | anthropic | bedrock | gemini | minimax | rubino-ui
  temperature: 0.3

agent:
  max_turns: 90
  max_tool_iterations: 8

memory:
  enabled: true
  backend: "sqlite"           # tiny-Zep FTS5 + graph-lite recall (default)
  auto_extract: true

compression:
  enabled: true
  threshold: 0.50

jobs:
  mode: "inline"              # inline | manual | worker

tools:
  workspace_strict: true      # sandbox write/edit/delete to the workspace
  git: true
  shell: true                 # ON by default; every command is still approval-gated
  ruby: true
  web: false                  # gates BOTH webfetch and websearch
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
- **[Memory](docs/memory.md)** — the SQLite tiny-Zep backend
- **[Security](docs/security.md)** — approval model, hardline floor, TLS
- **[Troubleshooting](docs/troubleshooting.md)** — keyed on the exact error strings
- **[HTTP API](docs/api/v1.md)** · **[Jobs & cron](docs/jobs.md)** · **[OAuth providers](docs/oauth-providers.md)** · **[Architecture](docs/architecture.md)**
- **[Contributing](CONTRIBUTING.md)** · **[Changelog](CHANGELOG.md)**

## Built-in tools

The agent ships **29 built-in tools**: `read`, `summarize_file`, `write`, `edit`, `multi_edit`, `grep`, `glob`, `git`, `github`, `shell`, `shell_output`, `shell_tail`, `shell_input`, `shell_kill`, `ruby`, `run_tests`, `apply_patch`, `webfetch`, `websearch`, `question`, `todowrite`, `memory`, `session_search`, `attach_file`, `vision`, `skill`, `task`, `task_result`, `task_stop`. Each is gated by a `tools.<key>` config flag (opt-out) and the approval model. See **[docs/tools.md](docs/tools.md)**.

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

Every request carries `Authorization: Bearer <RUBINO_API_KEY>` except `GET /v1/health` and `GET /v1/metrics`. The server binds `127.0.0.1` by default — pass `--host 0.0.0.0` (or set `RUBINO_API_HOST`) to expose it, and only do so behind TLS or a trusted segment. For the web→agent hop the API can serve over a self-signed cert the client pins (`RUBINO_TLS=1`; read it with `rubino tls-cert`).

Full request/response shapes, the error envelope, and SSE replay are in **[docs/api/v1.md](docs/api/v1.md)**.

## Planned / on the roadmap

These are designed-in but not fully wired yet — don't depend on them in production:

- **MCP Support** — connect to Model Context Protocol servers via [ruby_llm-mcp](https://github.com/patvice/ruby_llm-mcp) ([docs/mcp.md](docs/mcp.md)).
- **Multi-Agent** — Build / Plan / Explore agents with `@mention` routing ([docs/agents.md](docs/agents.md)).
- **Plugin Hooks** — event hooks for extending behavior ([docs/plugins.md](docs/plugins.md)).

## Development

```bash
bundle install
bundle exec rspec               # run tests
bundle exec rubino doctor   # verify setup
```

See **[CONTRIBUTING.md](CONTRIBUTING.md)** for the full dev/test/release flow.

## License

[MIT](LICENSE).
