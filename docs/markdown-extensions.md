# Markdown extensions: agents, skills, commands & rules

rubino loads **agents, skills, commands, and project rules from plain markdown files**
(YAML frontmatter + a markdown body) — so you can extend rubino without writing Ruby, and
reuse portable extension packs. It's a first-class rubino capability, not a bridge to any
one tool.

rubino discovers these files under **both** its own locations (`~/.rubino/…`, `.rubino/…`)
**and** the widely-used `~/.claude/…` / `.claude/…` locations. So an existing markdown
extension pack from the ecosystem — [`everything-claude-code`](https://github.com/worldflowai/everything-claude-code)
is one example — works by copying its files into place, and a `CLAUDE.md` / `AGENTS.md` in
your project is read as project rules. (See [Security](#security): project-local files are
trust-gated and all loaded content is injection-scanned.)

## Project rules (context files)

rubino follows a **first-match-wins** precedence chain for project-instruction files:

| Tier | File | Scope | Notes |
|---|---|---|---|
| 1 | `.rubino.md` / `RUBINO.md` | Walks up to git root | YAML frontmatter stripped (rubino-own convention) |
| 2 | `AGENTS.md` / `agents.md` | cwd only | Whole file injected as-is |
| 3 | `CLAUDE.md` / `claude.md` | cwd only | Whole file injected as-is |
| 4 | `.cursorrules` | cwd only | Falls back to `.cursor/rules/*.mdc` if absent |

Only **one** file is loaded — the first tier that finds a match wins. Content is capped at
20,000 characters (head 70% + tail 20% truncation) and scanned for prompt injection via
`Security::ContentScanner` before injection. Pass `--ignore-rules` to skip context-file
loading entirely.

## Agents

Agent files live as `.md` files with YAML frontmatter in the Claude Code agent format.
Each file becomes a rubino `Agent::Definition`, registered into the agent registry.

### Where rubino looks

Scan order (low→high precedence; later tiers override earlier on name collision):

```
1. ~/.claude/agents/*.md       (user-level, Claude-ecosystem)
2. ~/.rubino/agents/*.md       (user-level, rubino-specific)
3. .claude/agents/*.md         (project-local, Claude-ecosystem)
4. .rubino/agents/*.md         (project-local, rubino-specific)
```

A file-defined agent whose name collides with a **built-in** (`build`, `plan`, `explore`,
`general`, `compaction`, `title`) **replaces** that built-in — project- and user-level files
explicitly author over defaults.

### Frontmatter format

```markdown
---
name: my-agent
description: "Analyzes Firebase logs and suggests fixes"
tools: "Bash Grep Read Write"
model: "sonnet"
maxTurns: 20
mcpServers: "filesystem"
disallowedTools: "Bash Edit"
---

You are a Firebase troubleshooting agent. When given an error log, …
```

Everything after the closing `---` is the system prompt body.

### Supported fields

| Field | Notes |
|---|---|
| `name` | Agent identifier; must be non-empty |
| `description` | Shown in agent listings |
| `tools` | Space/comma-separated Claude Code tool names → translated to rubino tools (or omitted = `:all`) |
| `model` | `sonnet`/`opus`/`haiku`/`inherit` aliases, or a full model ID passed through unchanged |
| `maxTurns` | Integer cap on tool iterations per turn |
| `mcpServers` | Space/comma-separated list of MCP server names to scope the agent to |
| `disallowedTools` | Space/comma-separated Claude Code tool names → deny rules (the agent can use everything *except* these) |
| `type` | `"primary"` makes it switchable via `/agent`; `"utility"` marks it utility; omitted/anything else = subagent (default) |

### Tool-name translation

| Claude Code | rubino |
|---|---|
| `Bash` | `shell` |
| `Glob` | `glob` |
| `Grep` | `grep` |
| `Read` | `read` |
| `Write` | `write` |
| `Edit` | `edit` |
| `MultiEdit` | `edit` |
| `WebSearch` | `web_search` |
| `WebFetch` | `web_fetch` |
| `Task` | `task` |
| `TaskOutput` | `task_result` (defunct) |
| `TaskStop` | `task_stop` (defunct) |
| `AskUserQuestion` | `question` |
| `TodoWrite` | `todo` |
| `NotepadEdit` | `memory` |
| `Skill` | `skill` |
| `EnterPlanMode` | skipped (plan mode is a mode switch, not a tool) |

Unknown tool names are dropped with a warning. An `EnterPlanMode` entry is silently skipped.
`TaskOutput`/`TaskStop` translate literally to `task_result`/`task_stop`, but those targets
are **no longer registered tools** — they were folded into `task_manage` (selected by `action`),
so the translated names resolve to nothing and are effectively dropped.

### Fields with no rubino equivalent (ignored)

These Claude Code agent fields are **silently noted and ignored** — a warning is printed,
the agent still loads:

- `color`, `effort`, `isolation`, `skills`, `initialPrompt`, `background`

`permissionMode: "bypassPermissions"` is also **not supported** — rubino has no
"bypass all prompts" mode for subagents; a warning is printed and the subagent uses
the normal approval policy.

## Skills

rubino scans the same directory layout Claude Code uses for skills:

```
.claude/skills/<name>/SKILL.md       (project-local, trust-gated)
~/.claude/skills/<name>/SKILL.md     (user-level, always trusted)
```

These are discovered **in addition to** the rubino-specific paths (`.rubino/skills`,
`~/.rubino/skills`). The Claude paths are scanned first, so a same-named skill in a
rubino path overrides the Claude copy. The existing 3-level progressive disclosure
(index → body → references) and the `skill` tool work identically for skills loaded
from these paths. The agent-neutral `.agents/skills/` dir is also scanned at lowest
precedence. See [skills.md](skills.md) for the full skill model.

### Skill template tokens

`${RUBINO_SKILL_DIR}` in a skill body expands to the skill's directory on disk, so a
skill can reference its own bundled files. `${RUBINO_SESSION_ID}` resolves to the
current session id.

### Shell injection in skill bodies (`` !`cmd` ``)

Shell-injection blocks (`` !`command` ``) inside skill templates are **disabled by
default**. Set `skills.inline_shell: true` to enable them — only do so in trusted,
controlled environments. (This is a separate config key from `commands.shell_injection_enabled`,
which gates the same `` !`cmd` `` syntax in custom **command** templates — see
[Commands](#commands) below.)

## Commands

Custom slash commands in the Claude Code format are discovered from:

```
.claude/commands/*.md       (project-local, trust-gated)
~/.claude/commands/*.md     (user-level, always trusted)
```

These are scanned **before** the rubino-specific paths (`.rubino/commands`,
`~/.rubino/commands`), so a same-named command in a rubino path overrides.

### Template variables

| Variable | Meaning |
|---|---|
| `$ARGUMENTS` | All arguments passed after the command name |
| `$1` … `$9` | Positional arguments |
| `@path/to/file` | Replaced with the file's content (UTF-8) |

YAML frontmatter is **tolerated** — `name`, `description`, `argument-hint`, `agent`,
and `model` fields are read; unknown fields are ignored. A file with no frontmatter
still works (name falls back to basename). The rendered template is scanned for
prompt injection via `ContentScanner`.

### Notes on `allowed-tools` and other Claude Code command fields

Claude Code commands support `allowed-tools` in frontmatter to restrict tool access
during that command. rubino **tolerates** this field (the command still loads) but
does **not enforce** it — the agent retains full tool access during a custom command.
`bypassPermissions` is likewise a no-op.

## Security

### Trust gating

Project-local directories (`.claude/`, `.rubino/`) are **trust-gated**: when the
primary workspace root is untrusted, project-local agents, skills, and commands are
skipped — only user-level `~/.claude/` and `~/.rubino/` paths are loaded.

This protects against a hostile repo that ships a `.claude/agents/` with a
malicious system prompt: the agent definition is never parsed or injected until you
explicitly trust the folder (`rubino chat` from within it triggers the trust gate).

### Content scanning

Every externally-loaded `.md` body — agent system prompts, skill bodies, command
templates, and context files (`.rubino.md`, `AGENTS.md`, `CLAUDE.md`, `.cursorrules`) —
is scanned for prompt-injection and promptware patterns by `Security::ContentScanner`.

A match **blocks** the content: it is replaced with a `[CONTENT BLOCKED: …]` placeholder
before it ever reaches the model, and a structured `content_scan.blocked` event is
logged with the source path and matched category. Clean content passes through unchanged.

This mirrors Hermes's two-layer defence (shared pattern set + block-on-match behaviour
for context files) and runs at all four wiring points: context files, agent `.md` files,
skill bodies, and command templates. Memory writes go through the separate,
memory-specific `Memory::ThreatScanner` instead — a different pattern set tuned for a
long-lived, cross-session channel (see [memory.md](memory.md)).

## Honest limitations

These are the gaps between Claude Code's agent/skill/command model and rubino's
implementation — they are **intentional** and documented here so nothing looks like
a silent bug:

- **`allowed-tools` on commands/agents is tolerated but NOT enforced.** The agent
  runs with its full tool access during a custom command, regardless of what the
  command's frontmatter declares.
- **`bypassPermissions` is a no-op.** rubino has no per-agent "bypass all prompts"
  mode; the subagent uses the normal approval policy. A warning is printed when
  the field is encountered on an agent definition.
- **Per-agent `skills` is ignored.** Claude Code agents can attach skill files at
  creation time; rubino loads skills through the system prompt/skill tool instead.
- **`effort`, `isolation`, `color`, `initialPrompt`, `background`** on agent
  definitions are silently ignored (a warning is printed to stderr).
- **`` !`cmd` `` shell injection in skills is off by default.** Requires
  `skills.inline_shell: true` (a separate key from `commands.shell_injection_enabled`,
  which only gates command templates).
- **MCP OAuth** in rubino is not implemented; whatever behaviour you get is from
  the installed `ruby_llm-mcp` version. See [mcp.md](mcp.md#authentication).
