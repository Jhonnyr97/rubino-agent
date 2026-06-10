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
| `--resume` | `-r` | Resume a session by ID prefix, or by a substring of its title or full first prompt |
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
- In interactive chat, a line containing **only** an image stages the attachment — it is sent with your next message; `/clear-images` drops **everything** staged, however it was added (`/paste`, `@image` token, `--image`, or a dropped path). A line with text *and* an image sends both immediately.
- `/paste` reads the clipboard via an external tool: `pngpaste` on macOS, `wl-paste` or `xclip` on Linux. When none is installed it warns instead of failing silently.

### Auto-resume and continuity

- A **bare** interactive `rubino chat` auto-resumes your most recent resumable session and replays its history.
- `--new` forces a fresh session; `--continue`/`-c` resumes the latest; `--resume`/`-r <id|title>` resumes a specific one.
- `--resume` matches an ID prefix first, then a case-insensitive substring of the session title **or its full first prompt** — so a memorable phrase from the tail of a long first message works even though the stored title is truncated. More than one match is an error listing the candidates; no match exits non-zero with a pointer to `rubino sessions list`.
- One-shot mode (`-q` / `prompt`) does **not** auto-resume — automation isn't silently hijacked onto a past session; pass `--resume`/`--continue` explicitly if you want it.
- One-shot output: when stdout is a **terminal** the answer renders through the same markdown pipeline as interactive chat (styled text, fitted tables, wrapping); when stdout is **piped/redirected** the answer stays plain raw text and diagnostics go to stderr, so `$(rubino prompt …)` stays clean.
- Sessions are marked ended on clean exit, terminal close (SIGHUP), or kill (SIGTERM), so a closed window doesn't leave a session looking active.

### Exit codes (scripting around `prompt` / one-shot)

- `rubino prompt` / `chat -q` exits **0** whenever the run completes and an
  answer is printed — including when a tool request was **cleanly refused** by
  policy along the way (a write outside the workspace boundary, a denied
  approval, a hardline-blocked command). A refusal the agent handled and
  explained is expected behavior, not an error.
- It exits **non-zero** when the run itself fails: no usable credentials, the
  `--resume`/`--session` target doesn't exist or is ambiguous, or the provider
  call errors out. The reason is printed to stderr; the answer (when any) stays
  on stdout.
- `rubino doctor` exits **non-zero** when one or more required checks fail, so
  CI can gate on it. Unknown subcommands also exit non-zero.

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
| `/queued` | Queue a message to run after the current turn (Alt+Enter does the same) |
| `/branch` | Fork the current session into a new one and switch into it |
| `/memory` | Inspect/search/forget what the agent remembers |
| `/agents` | List background subagents; steer/probe a running one, or view output |
| `/tasks` | Alias for /agents |
| `/reply` | Answer a subagent that is blocked waiting on you (ask_parent) |
| `/skills` | List skills, or activate one for the session (/skills NAME; 'none' clears) |
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

### Typing while the agent is working

You can keep typing while a turn is running — the pinned input stays live:

- **Enter** interrupts the current turn and runs your line as the **next** turn (the partial answer is kept and marked `⎿ interrupted`).
- **Alt+Enter** queues the line **without** interrupting: it runs after the current turn finishes, with a live `⏳ queued:` indicator above the input until it does.
- **`/queued <message>`** is the terminal-independent fallback for Alt+Enter (some terminals don't deliver the chord) — it queues the message the same way.

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

### Active skill: `/skills`

- Bare `/skills` lists the available skills (with `(disabled)` / `(active)` markers).
- `/skills <name>` **activates** a skill for the session: its body is force-loaded into the system prompt each turn and the prompt chip shows it — `default (skill: <name>) ❯`. Typing `/skills ` opens a dropdown picker of skill names, headed by a `✗ none` clear entry.
- `/skills none` (or picking `✗ none`) clears the active skill: `✓ Cleared active skill (was: <name>).`
- Activation is trust-gated: a project-local skill in an untrusted directory is refused with a reason instead of being pinned without effect.

Activating is **not** the same as enabling/disabling — see [skills.md](skills.md#active-skill-skills) for the distinction.

### Reasoning display and thinking effort

While the model reasons, the CLI shows a live animated status row — a pulsing glyph with an elapsed counter (`✻ thinking…  3s`). When the first answer token arrives the row is torn down and the buffered reasoning collapses per the active render mode:

- `collapsed` (default) — a dim one-liner cue: `┄ ✻ thought for 3s · ctrl-o to show ┄`.
- `full` — the whole reasoning committed as a dim `┊` aside above the answer.
- `hidden` — nothing is shown, but the last thought is still retained.

**Ctrl+O** reveals the last retained reasoning as the `┊` aside — in `collapsed` mode after the cue, and in `hidden` mode on demand. The reveal is one-way scrollback (a second press is a silent no-op until a new thought arrives).

Two orthogonal knobs control all this (persisted to config, so they survive the session):

- `/reasoning [hidden|collapsed|full]` controls how the reasoning stream is **rendered**, as above. Bare `/reasoning` shows the current mode. Writes `display.reasoning`.
- `/think [off|low|medium|high]` controls how much thinking **effort** is requested from the model, mapped to an Anthropic-style thinking-token budget (`off`→0, `low`→4000, `medium`→8000, `high`→16000). Bare `/think` shows the current effort (default `medium`). Writes `thinking.effort`.

**Provider caveat:** some anthropic-compatible backends reject thinking budgets. The first such turn is retried once without the budget and a dim `provider doesn't support thinking — effort off` note is printed; the rejection is remembered for the session. Set `/think off` (or `thinking.effort: "off"` in config — quote the `"off"`, bare YAML `off` parses as `false`) to skip the retry entirely. See [configuration.md](configuration.md#reasoning--thinking).

### Custom commands and `--preview`

Custom commands live as Markdown templates in `.rubino/commands/` (project) or `~/.rubino/commands/` (global) and are invoked by their name, e.g. `/test authentication module`. Append `--preview` anywhere in the arguments to render the template **without running it**:

```
/test authentication module --preview
```

`/commands` lists the available custom commands and explains how to author them. See the [README](../README.md) for the template format (`$ARGUMENTS`, YAML frontmatter).

### Modes

`/mode` (or the `--yolo` flag) switches between the modes below. **Shift+Tab** cycles them from the prompt (default → plan → yolo) and shows a transient `mode <old> → <new>` footer. Entering `yolo` from the cycle takes a second deliberate Shift+Tab to confirm (the toast says so, and warns when running background subagents would lose their approval gates); an explicit `/mode yolo` switches directly.

- `default` — approval-gated tools prompt as configured.
- `plan` — read-only: the registry is pared down so mutating tools (`edit`, `shell`, `git`, …) aren't even offered to the model.
- `yolo` — skip approval prompts (but the hardline floor and explicit `permissions: deny` rules still apply). See [security.md](security.md).
