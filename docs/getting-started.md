# Getting started

From nothing to a working first answer in about five minutes. This is the happy path; the model/key decision is made interactively, not by hand-editing YAML.

## 1. Install

The fastest path on Linux and macOS (x86_64 / arm64) is the one-line installer. It installs a compatible Ruby and then the gem — all in user space, no sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/Jhonnyr97/rubino-agent/main/install.sh | bash
```

Piping a script into your shell runs whatever it contains, so review it first if you like:

```bash
curl -fsSL https://raw.githubusercontent.com/Jhonnyr97/rubino-agent/main/install.sh -o install.sh
less install.sh && bash install.sh
```

On Linux it offers a choice of Ruby provider — [`rv`](https://github.com/spinel-coop/rv) or [`mise`](https://mise.jdx.dev) (and Homebrew if `brew` is already present on macOS); pick non-interactively with `RUBINO_INSTALL_METHOD=rv|mise|brew`. On a **Debian 12 / old-glibc** box, prefer **mise**: `rv`'s musl build there yields a Ruby this glibc system can't run, so the installer steers `rv → mise` automatically. (For the mise method, `RUBINO_INSTALL_SCOPE=global|local` chooses user-wide vs this-directory-only. See the [README install matrix](../README.md#install).)

The installer is idempotent (safe to re-run). When it finishes it **persists the activation / `PATH` line to your shell rc** (`.zshrc` / `.bashrc` / `.profile`) and then **verifies in a fresh shell** that `rubino` is on `PATH`, failing loudly if it isn't — so a new terminal just works. Opt out of rc edits with `RUBINO_NO_MODIFY_RC=1` (it then prints the line for you to add).

**Already manage Ruby yourself?** Requirements are Ruby >= 3.1 and SQLite3; then:

```bash
gem install rubino-agent
```

Verify the binary is on your `PATH`:

```bash
rubino version
```

In a development checkout, prefix commands with `bundle exec` (`bundle exec rubino ...`).

## 2. Run the setup wizard

```bash
rubino setup
```

`setup` creates the home directory (`~/.rubino`, mode `0700`), a default `config.yml` (`0600`), an `.env` template (`0600`), and initializes the SQLite database with all migrations. Then, **if no usable API key is configured and you're on a real terminal**, it launches the onboarding wizard:

```
Welcome to rubino — let's get you connected to a model.
No API key is configured yet. Pick a provider (or press Enter to skip).

  1) OpenAI (GPT) — recommended default
  2) MiniMax (Anthropic-compatible)
  3) Anthropic (Claude)
  4) Google (Gemini)
  5) OpenAI-compatible gateway
Choose a provider [1-5, Enter to skip]: 1
Paste your OPENAI_API_KEY (input hidden; Enter to skip): ••••••••
Configured OpenAI (GPT) — recommended default with model gpt-4.1.
Saved to ~/.rubino/config.yml and ~/.rubino/.env.
```

What the wizard does, exactly:

- Writes `model.default` and `model.provider` for the chosen provider into `config.yml`.
- Writes any provider block it needs (e.g. MiniMax sets `providers.minimax.base_url` + `anthropic_compatible: true` + `api_key: ${MINIMAX_API_KEY}`).
- Appends `KEY=value` to `~/.rubino/.env` (mode `0600`); the key is **never echoed back** and is exported into the current process so the very next message works.
- The **OpenAI-compatible gateway** option additionally asks for the gateway base URL.

The defaults written per provider:

| Choice | provider | default model | key var |
|---|---|---|---|
| OpenAI (default) | `openai` | `gpt-4.1` | `OPENAI_API_KEY` |
| MiniMax | `minimax` | `MiniMax-M2.7` | `MINIMAX_API_KEY` |
| Anthropic | `anthropic` | `claude-sonnet-4-5` | `ANTHROPIC_API_KEY` |
| Google | `google` | `gemini-2.5-pro` | `GEMINI_API_KEY` |
| OpenAI-compatible gateway | `gateway` | `auto` | `OPENAI_API_KEY` |

Press **Enter** at the provider prompt to skip. You can also configure things by hand — see [models-and-keys.md](models-and-keys.md).

## 3. Start chatting

```bash
rubino chat
```

The first thing you see is a banner with the workspace, git branch, and model. The input line leads with a red `▍` rail and a clean `❯` caret; the dim status bar underneath shows the session mode, model, and context saturation. Then ask something:

```
▍❯ what does this project do?
 default · openai/gpt-4.1 · ctx ~0/128k
```

> If you skipped the wizard during `setup`, a bare `rubino chat` re-runs it before the first turn (when on a TTY). If you're piping input or using `-q`, there's no prompt to run — instead you get a clear, actionable error telling you how to set a key (see below).

## 4. Make a first edit

Ask the agent to change something:

```
▍❯ add a docstring to the top of lib/foo.rb
```

When the agent wants to run `shell` (or any approval-gated tool), it pauses and asks for your decision. Approve once, approve for the session, or deny — see [security.md](security.md) for the full approval model.

You can keep typing while the agent works: **Enter** interrupts the current turn and runs your line next; **Alt+Enter** (or `/queued <message>`) queues it to run after the turn finishes. See [commands.md](commands.md#typing-while-the-agent-is-working).

## 5. Exit and resume

Type `exit` (or `/exit`, Ctrl+D, or a double Ctrl+C) to end the session. On exit you get a resume hint:

```
Resume with: rubino chat --resume "my session title"
```

Resuming:

- `rubino chat` — a **bare** interactive chat auto-resumes your most recent resumable session and replays its history.
- `rubino chat --new` — force a fresh session instead.
- `rubino chat --continue` (`-c`) — resume the most recent session explicitly.
- `rubino chat --resume <id|title>` (`-r`) — resume a specific session.

In-chat, `/sessions` lists recent sessions and resumes one in place, and `/new` starts a fresh one without leaving the REPL.

## If the first message fails

A brand-new user with no key used to see ~80 seconds of silent retries then an empty answer. That trap is fixed: the run now fails fast with guidance. In a non-interactive context (e.g. `rubino prompt "hi"` with no key) you'll see:

```
No API key configured for provider 'openai' (model openai/gpt-4.1).
Set it up one of these ways:
  • run `rubino setup` for a guided first-run setup, or
  • add OPENAI_API_KEY=<your-key> to ~/.rubino/.env, or
  • set providers.openai.api_key in ~/.rubino/config.yml.
```

(The shipped default model `openai/gpt-4.1` resolves to OpenRouter in ruby_llm's registry; this is why a first run without a key or the right provider fails. The cleanest fix is `rubino setup`. See [models-and-keys.md](models-and-keys.md) and [troubleshooting.md](troubleshooting.md).)

Run `rubino doctor` at any time to check config, the resolved provider, credentials, and database health.

## Next steps

- [Models & keys](models-and-keys.md) — per-provider setup blocks and the default→OpenRouter note.
- [Commands](commands.md) — every CLI subcommand and slash command.
- [Configuration](configuration.md) — full reference, env vars, precedence.
- [Tools](tools.md) — what the agent can do and how each tool is gated.
