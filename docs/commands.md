# Commands

Two surfaces: **CLI subcommands** (run from your shell) and **slash commands** (typed inside an interactive `rubino chat`). The slash table below is the canonical set from `lib/rubino/commands/built_ins.rb` (`BuiltIns::DESCRIPTIONS`) — the same source `/help` and tab-completion read, so the two never drift.

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

### Image attachments

- `--image PATH` (repeatable), `@path/to/pic.png` tokens, and dropped/quoted paths in the prompt all attach images to the model's native vision slot.
- `@` tokens and dropped paths resolve **relative to the current working directory**; a token that isn't a readable image file is left as literal text in the prompt (not an error).
- Every candidate is validated by the attachment policy ([`attachments.policy`](configuration.md#attachments): content classification by magic bytes + the 25 MB `max_file_bytes` cap) **before** any network call. A rejected file is a clean one-line error in one-shot mode, or a warning (and the file is not attached) in interactive chat.
- In one-shot mode a `sending image (N MB)…` status line is printed to stderr before the upload, so a large attachment doesn't look like a freeze.
- In interactive chat, a line containing **only** an image stages the attachment — it is sent with your next message; `/clear-images` drops anything staged. A line with text *and* an image sends both immediately.

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

Type these inside `rubino chat`. Generated from `BuiltIns::DESCRIPTIONS`:

| Command | Description |
|---|---|
| `/status` | Overview: model, mode, session, memory, background work |
| `/sessions` | List recent sessions and resume one |
| `/new` | Start a fresh session (the current one is left intact) |
| `/memory` | Inspect/search/forget what the agent remembers |
| `/agents` | List background subagents and view their output |
| `/tasks` | Alias for `/agents` |
| `/skills` | List available skills |
| `/mode` | Show or switch mode (`default` \| `plan` \| `yolo`) |
| `/commands` | List custom commands (and how to make them) |
| `/help` | Show this help |
| `/paste` | Attach an image from the clipboard (requires `pngpaste` on macOS, `wl-paste` or `xclip` on Linux; warns when none is installed) |
| `/clear-images` | Drop **all** pending image attachments, however they were staged (`/paste`, `@image` token, or a dropped path on an image-only line) |
| `/exit` | End session |
| `/quit` | End session |

(`exit`, `quit`, and `bye` without a slash also end the session; Ctrl+D and a double Ctrl+C do too.)

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
