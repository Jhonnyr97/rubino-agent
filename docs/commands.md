# Commands

Two surfaces: **CLI subcommands** (run from your shell) and **slash commands** (typed inside an interactive `rubino chat`). The slash table below mirrors `lib/rubino/commands/built_ins.rb` (`BuiltIns::DESCRIPTIONS`) — the same source `/help` and tab-completion read — and a spec (`spec/docs/commands_doc_drift_spec.rb`) asserts the table matches that map, so it cannot drift unnoticed.

## CLI subcommands

| Command | Description |
|---|---|
| `rubino setup` | Initialize config + database; run the first-run onboarding wizard on a TTY |
| `rubino chat [PROMPT]` | Interactive chat (or one-shot with `-q`/a positional prompt) |
| `rubino prompt PROMPT` | One-shot, non-interactive (alias for `chat -q`) |
| `rubino config SUBCOMMAND` | Manage configuration (`get` / `set` / `show`) |
| `rubino memory SUBCOMMAND` | Manage persistent memories (`list` / `show` / `delete` / `backend`) |
| `rubino sessions SUBCOMMAND` | Manage chat sessions |
| `rubino jobs SUBCOMMAND` | Manage background jobs |
| `rubino tools` | List available tools and their enabled/disabled state |
| `rubino server` | Start the JSON API + SSE server |
| `rubino tls-cert` | Print the agent's self-signed TLS certificate PEM (generating it if absent) |
| `rubino doctor` | Check system health (config, resolved provider, credentials, database) |
| `rubino version` | Show the version |
| `rubino update` | Update rubino to the latest published version (via RubyGems) |

A bare `rubino "my prompt"` is shorthand for `chat` with that prompt.

### update + the boot "update available" notice

`rubino update` runs `gem update rubino-agent` under the active interpreter
(`Gem.ruby -S gem update rubino-agent` — argv form, no shell, multi-Ruby safe),
then reports the new version (or "already up to date"). If rubino was built from
source / a dev checkout (not installed from RubyGems), it prints installer
guidance instead of attempting a gem update.

On interactive (TTY) boot, rubino shows a single dim line when a newer version
is available:

```
▸ rubino v0.4.1 available — run `rubino update`
```

This notice is sourced purely from a local cache (`<RUBINO_HOME>/update_check.json`)
so it never slows startup; the RubyGems check that refreshes the cache runs
out-of-band on a detached, short-timeout thread (gated to once / 24h) and only
affects the *next* boot. It is silent offline and prints nothing until the gem
is actually published.

Set `RUBINO_NO_UPDATE_CHECK=1` to disable the check entirely (no network, no
notice, no thread). It is also auto-disabled when stdout is not a TTY or `CI`
is set.

### chat / prompt flags

| Flag | Alias | Meaning |
|---|---|---|
| `--query` | `-q` | One-shot prompt (non-interactive) |
| `--image` | `-i` | Attach image file(s) (repeatable); `@image` tokens in the prompt also work |
| `--session` | `-s` | Resume a session by ID |
| `--resume` | `-r` | Resume a session by ID or title |
| `--continue` | `-c` | Resume the most recent session |
| `--new` | | Start a fresh session (bare `chat` resumes the last one by default) |
| `--model` | `-m` | Override the model (e.g. `claude-sonnet-4-5`) |
| `--provider` | | Override the provider (e.g. `anthropic`, `bedrock`) |
| `--yolo` | | Skip approval prompts (equivalent to `/mode yolo`) |
| `--max-turns` | | Max tool iterations per turn |
| `--ignore-rules` | | Skip `AGENTS.md` and context files |

### Auto-resume and continuity

- A **bare** interactive `rubino chat` auto-resumes your most recent resumable session and replays its history.
- `--new` forces a fresh session; `--continue`/`-c` resumes the latest; `--resume`/`-r <id|title>` resumes a specific one.
- One-shot mode (`-q` / `prompt`) does **not** auto-resume — automation isn't silently hijacked onto a past session; pass `--resume`/`--continue` explicitly if you want it.
- Sessions are marked ended on clean exit, terminal close (SIGHUP), or kill (SIGTERM), so a closed window doesn't leave a session looking active.

### server flags

| Flag | Default | Meaning |
|---|---|---|
| `--port` | `4820` | Port to listen on |
| `--host` | `127.0.0.1` | Interface to bind (`0.0.0.0` to expose; do so only behind TLS or a trusted segment) |
| `--api_key` | | Bearer token required on every request |

### config / memory / sessions / jobs subcommands

```bash
rubino config get KEY        # read a config value
rubino config set KEY VALUE  # write a config value
rubino config show           # print the full effective config

rubino memory list           # list stored memories (active backend)
rubino memory show ID
rubino memory delete ID
rubino memory backend [NAME] # show the active memory backend, or switch to NAME

rubino sessions list
rubino sessions show ID
rubino sessions compact ID
rubino sessions delete ID

rubino jobs list
rubino jobs process          # run pending jobs now (manual mode)
rubino jobs worker           # start a background worker
```

See [memory.md](memory.md) for the memory backends and [jobs.md](jobs.md) for the queue/cron system.

---

## Slash commands

Type these inside `rubino chat`. Generated from `BuiltIns::DESCRIPTIONS` (drift-checked by `spec/docs/commands_doc_drift_spec.rb`):

| Command | Description |
|---|---|
| `/status` | Overview: model, mode, session, memory, background work |
| `/sessions` | List recent sessions and resume one |
| `/new` | Start a fresh session (the current one is left intact) |
| `/probe` | Ask an ephemeral side-question (not saved); tip: start a line with '? ' |
| `/branch` | Fork the current session into a new one and switch into it |
| `/memory` | Inspect/search/forget what the agent remembers |
| `/agents` | List background subagents; steer/probe a running one, or view output |
| `/tasks` | Alias for /agents |
| `/reply` | Answer a subagent that is blocked waiting on you (ask_parent) |
| `/skills` | List available skills |
| `/add-dir` | Add an extra allowed workspace directory (write/edit can reach it) |
| `/dirs` | List the current workspace roots |
| `/mode` | Show or switch mode (default \| plan \| yolo) |
| `/reasoning` | Show or switch how reasoning is shown (hidden \| collapsed \| full) |
| `/think` | Show or switch thinking effort (off \| low \| medium \| high) |
| `/commands` | List custom commands (and how to make them) |
| `/help` | Show this help |
| `/paste` | Attach an image from the clipboard |
| `/clear-images` | Drop pending image attachments |
| `/exit` | End session |
| `/quit` | End session |

(`exit`, `quit`, and `bye` without a slash also end the session; Ctrl+D and a double Ctrl+C do too.)

### Probes and branches

- `/probe <question>` is the discoverable alias for the `? ` prefix: an **ephemeral** side-question answered from the current context but **never saved** to the session — the next turn proceeds as if it never happened. Bare `/probe` just teaches the `? ` prefix.
- `/branch [title]` forks the current session here into a **new saved session** (optionally titled) and switches into it, so you can explore an alternative direction; the original session stays intact.

### Background subagents: `/agents` and `/reply`

The agent spawns background subagents with its `task` tool; these commands are the human surface over them (full model in [agents.md](agents.md)):

```
/agents                       # list background subagents (status, activity)
/agents <id>                  # drill in: live watch while running, result/error when done
/agents <id> --stop           # cancel a running subagent (blocked descendants unwind too)
/agents <id> steer "note"     # park a note folded into the child's context at its next turn
/agents <id> probe "question" # ephemeral read-only peek — nothing is saved to the child
/reply <id> <answer>          # answer a subagent blocked on an ask_parent question
/reply                        # bare: list the subagents currently blocked on you
```

`/tasks` is an alias for `/agents`.

### Workspace roots: `/add-dir` and `/dirs`

The workspace sandbox confines write/edit/delete tools to the workspace roots. `/add-dir <path>` adds an extra allowed root mid-session (and runs the one-time folder-trust gate, so the new root's `AGENTS.md`/skills are only honored once vouched for); `/dirs` lists the current roots and their trust state.

### Reasoning display and thinking effort

Two orthogonal knobs (persisted to config, so they survive the session):

- `/reasoning [hidden|collapsed|full]` controls how the model's reasoning stream is **rendered**: `hidden` (nothing shown), `collapsed` (the default — a compact indicator, with Ctrl+O revealing the last retained reasoning), or `full` (the whole stream as a dim aside). Bare `/reasoning` shows the current mode. Writes `display.reasoning`.
- `/think [off|low|medium|high]` controls how much thinking **effort** is requested from the model (mapped to a provider thinking-token budget; `off` disables thinking). Bare `/think` shows the current effort (default `medium`). Writes `thinking.effort`.

### Custom commands and `--preview`

Custom commands live as Markdown templates in `.rubino/commands/` (project) or `~/.rubino/commands/` (global) and are invoked by their name, e.g. `/test authentication module`. Append `--preview` anywhere in the arguments to render the template **without running it**:

```
/test authentication module --preview
```

`/commands` lists the available custom commands and explains how to author them. See the [README](../README.md) for the template format (`$ARGUMENTS`, YAML frontmatter).

### Modes

`/mode` (or the `--yolo` flag) switches between:

- `default` — approval-gated tools prompt as configured.
- `plan` — read-only: the registry is pared down so mutating tools (`edit`, `shell`, `git`, …) aren't even offered to the model.
- `yolo` — skip approval prompts (but the hardline floor and explicit `permissions: deny` rules still apply). See [security.md](security.md).
