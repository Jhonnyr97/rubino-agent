# Skills

Skills are reusable instruction packs the agent can pull into context when a task
calls for them. A skill bundles specialized knowledge — APIs, tool-specific
commands, proven workflows, and your team's conventions and quality bars — into a
single `SKILL.md` (plus optional bundled reference files). Instead of bloating
every prompt with that knowledge, the agent sees a short *index* of available
skills up front and loads the full instructions only for the ones that are
relevant.

## What a skill is

A skill is a Markdown file (with YAML frontmatter) and, optionally, a directory of
bundled files alongside it. The agent treats a loaded skill's body as authoritative
instructions for the matching task.

### Where skills live

By default the registry scans two directories (project-local first, then the
home-level one):

```yaml
# config: skills section (docs/configuration.md#skills)
skills:
  enabled: true
  paths:
    - ".rubino/skills"     # project-local
    - "~/.rubino/skills"   # shared across projects
```

Override the search paths via the `skills.paths` config key. On a name collision
the **directory** layout wins over the flat-file layout (it is the richer unit).

The registry additionally scans the **agent-neutral** skill dirs — project
`.agents/skills/` and `~/.agents/skills/` (the emerging cross-agent convention
used by `npx skills`, Gemini CLI, goose) — at the lowest precedence: a
rubino-path skill of the same name wins, and nothing changes when those dirs
are absent. The project-local one is trust-gated exactly like `.rubino/skills`.

### Two layouts

| Layout | Path | Skill name | Bundled files |
| --- | --- | --- | --- |
| Directory (preferred) | `<dir>/<name>/SKILL.md` | the directory name | yes — anything next to `SKILL.md` |
| Flat file (legacy) | `<dir>/<name>.md` | the file basename | no |

The directory layout matches the Claude skill format and is preferred
because it can carry bundled references, scripts, and assets.

### Built-in (gem-bundled) skills

On top of the configured user paths, the registry **always** scans the
`skills/` directory shipped *inside the gem*. This is how a skill reaches every
install with no copy step and updates automatically on `gem update`. The bundled
**`ruby-expert`** skill (deep Ruby/Rails knowledge across idioms, OO design,
concurrency, Rails, testing, performance, security, and more) ships this way.

Built-ins are scanned **before** the user paths, so a user skill of the same
name placed in `.rubino/skills` or `~/.rubino/skills` transparently overrides the
built-in (last writer wins on the name-indexed merge). To run with only your own
skills, set:

```yaml
skills:
  include_builtin: false   # default true
```

### Installing skills from git (`rubino skills install`)

Any git repo shipping the `<name>/SKILL.md` layout is a skill source — there is
no marketplace and nothing else is vendored in the gem. Skills are
shallow-cloned and copied into `~/.rubino/skills`, where the registry discovers
them like any hand-written skill:

```bash
rubino skills install anthropics/skills --list        # see what a source ships
rubino skills install anthropics/skills --skill pdf   # pick by name (repeatable)
rubino skills install owner/repo --all                # take everything
rubino skills install https://gitlab.com/o/r.git      # any git URL works
rubino skills install --documents                     # anthropics/skills: pdf docx pptx xlsx
rubino skills update                                  # re-fetch installed skills
rubino skills remove NAME                             # delete dir + provenance
```

With no `--skill`/`--all` and multiple skills in the source, the CLI prints the
catalogue and asks you to pick (off a TTY it just prints the hint). Provenance
is recorded per installed skill in `~/.rubino/skills/.sources.json`
(`name → {source, path, commit}`): `rubino skills list` shows it in the Source
column, and `update` re-fetches from the recorded source, reporting
*up to date* vs *updated* by comparing commits. `remove` only deletes skills
this mechanism installed — hand-written skills are never touched.

### Authoring a `SKILL.md`

A `SKILL.md` is YAML frontmatter followed by the instruction body:

```markdown
---
name: pdf-extraction
description: Extract text and tables from PDFs using markitdown; handles scanned pages.
---

# PDF extraction

When the user gives you a PDF, prefer `markitdown <file>` over ad-hoc parsers.
For scanned/image PDFs, first OCR with ... (full instructions here).

See `references/markitdown-flags.md` for the flag cheatsheet.
```

Frontmatter fields the registry reads:

- **`name`** — the skill's invocation name. If omitted, it defaults to the
  directory name (directory layout) or the file basename (flat layout).
- **`description`** — the one-liner shown in the index. This is the *only* text the
  agent sees before deciding to load the skill, so make it match-on-sight: say
  what the skill is for and when it applies.

Everything after the closing `---` is the body that gets loaded at Level 2 (below).
A skill with no frontmatter still works: the name falls back to the basename and the
description falls back to the first heading line.

Bundled files in the directory layout live anywhere under the skill dir (e.g.
`references/api.md`, `scripts/run.py`). VCS and junk dirs (`.git`, `node_modules`,
`__pycache__`, …) are excluded. Bundled-file reads are sandboxed to the skill's own
directory — paths that escape it (via `..`, absolute paths, or out-of-dir symlinks)
are rejected.

## The 3-level progressive disclosure

The core idea: the agent should *know which skills exist* without paying the token
cost of reading them all, then pull in the full text only for the one(s) it
actually needs. This happens in three levels.

### Level 1 — DISCOVERY (the index)

At the start of a turn the system prompt carries a `## Skills` block listing every
enabled skill as `name: description` — and nothing more. The agent knows a skill
exists and what it is for, but has **not** read its instructions. This index is the
load-bearing auto-trigger: surfacing the catalogue in the system prompt (not just in
the `skill` tool's description) is what makes the model proactively scan for a
relevant skill before replying.

Disabled skills are excluded from the index, so a skill toggled off never appears.

### Level 2 — SKILL LOADED (the body)

When the agent decides a skill is relevant it calls the `skill(name)` tool, which
pulls the **full `SKILL.md` body** into context. This is the moment a skill goes
from *"the agent knows it exists"* to *"the agent is using it"* — the actual unit of
skill **usage**.

This is exactly the event you want to measure. Loading a body:

- returns the body (prefixed `Skill '<name>' loaded:`) to the model, and
- if the skill is a directory with bundled files, appends a list of those files so
  the model knows what it can pull next, and
- emits the `SKILL_LOADED` observability signal (see below).

If the named skill doesn't exist, the tool returns the list of available skills; if
it exists but is disabled, it returns a distinct "disabled" message.

### Level 3 — REFERENCES (bundled files on demand)

The body can point at bundled reference files. The agent loads one by calling the
same tool with a `file_path`:

```
skill(name: "pdf-extraction", file_path: "references/markitdown-flags.md")
```

The file's contents are read (sandboxed to the skill dir) and returned. This keeps
deep reference material out of context until the moment it's needed. A `file_path`
that isn't found returns the live list of available bundled files instead.

So the disclosure ladder is: **index (Level 1) → body (Level 2) → references
(Level 3)**, each step pulled in only when warranted.

## Creating skills

Beyond loading existing skills, the agent can author new ones so a complex,
repeatable task is captured once and reused. There are two mechanisms — both
gated by `skills.enabled` (default true).

### 1. Deterministic post-turn distillation (primary)

After every turn, `DistillSkillJob` runs alongside `ExtractMemoryJob`. Its gate
is **fully deterministic** (no model call): it fires only when

- the run produced a non-empty final answer (succeeded), **and**
- the turn used at least `RA_DISTILL_TOOL_THRESHOLD` tool calls (default **5**,
  mirroring the reference "5+"), **and**
- no existing skill already covers the work.

Only on a gate-pass does it spend **one** auxiliary-LLM call to distil the
transcript into a `SKILL.md` candidate, which it writes to the first
`skills.paths` dir. Trivial sessions pass the gate zero times, so they cost zero
extra calls. Raise or lower the bound with `RA_DISTILL_TOOL_THRESHOLD`.

This is the mechanism that actually creates skills in practice: an A/B bench
found that a prompt nudge or an on-demand tool alone are ignored under load
(F1 = 0), while the deterministic post-turn job created good, reusable skills
with no false positives.

### 2. On-demand `skill(action: "create")` (manual)

The agent can also create a skill inline during a turn, with no extra LLM call:

```
skill(action: "create",
      name: "kebab-case-name",
      description: "What it's for and WHEN it applies.",
      body: "# Title\n\nProven step-by-step instructions and pitfalls.")
```

It validates the name (kebab-case, ≤64 chars), requires a non-empty description
(≤1024 chars) and body, writes `<name>/SKILL.md` with valid frontmatter, and
refuses to overwrite an existing skill. The new skill is immediately
discoverable. `action` defaults to `"load"`, so existing `skill(name:)` calls
are unaffected.

Both paths emit `SKILL_CREATED` (`{ name:, file_path: }`) on the turn-scoped bus
and count toward `skills_created_total` (see Observability).

## Observability

You can measure skill *use* — not just that skills exist — through one event and two
metrics (added in #132).

### The `SKILL_LOADED` event

When the `skill` tool successfully loads a body (Level 2), it emits `SKILL_LOADED`
on the turn-scoped event bus. The recorder/SSE layer surfaces it as **`skill.loaded`**
(parity with `tool.started`, `subagent.spawned`, etc.).

- **Internal symbol:** `Interaction::Events::SKILL_LOADED`
- **Recorder / SSE name:** `skill.loaded`
- **Payload:** `{ name: <skill name> }` (the run association — `run_id` — is stamped
  by the recorder, like every other event).

It fires once per successful body load. Loading a Level-3 bundled file does **not**
emit it — the signal tracks the level-2 "skill is now in use" transition.

### Metrics

Two Prometheus counters expose skill activity on `GET /v1/metrics`:

| Metric | Increments when | Measures |
| --- | --- | --- |
| `skills_loaded_total` | a skill body is successfully loaded via the `skill` tool (Level 2) | **usage / adoption** — how often skills are actually pulled in |
| `skills_created_total` | a skill not seen on the prior scan appears on a registry **re-scan** | **creation** — how often new skills show up |

Their registered HELP strings:

- `skills_loaded_total` — *"Number of times a skill was successfully loaded via the
  `skill` tool."*
- `skills_created_total` — *"Number of new skills observed by the registry on a
  re-scan (disk-diff signal; no creation tool exists)."*

**Why creation is a disk-diff, not a tool.** There is no skill-creation tool — the
agent (or a human) just writes files. So the cleanest in-process signal is the
registry noticing a name on a re-scan that wasn't there before. Consequences worth
knowing:

- The first scan is treated as initial enumeration and does **not** count existing
  skills as "created" — only a *re*-discover books new names.
- Counting is per new name that appears (`by: <count of new names>`).
- A skill removed and later re-added would be re-counted. That's fine for a usage
  signal; it is not a strict ledger.

**How to read them.** `skills_loaded_total` answers the adoption question — *"of the
sessions where a relevant skill existed, did the agent actually load it?"* Pair it
with `skills_created_total` to see whether newly authored skills are being picked up:
a rising creation count with a flat load count means new skills aren't getting used
(weak descriptions, wrong paths, or the index not triggering). Both are best-effort
instrumentation — they never alter skill-loading behavior.

## The `skill` tool

The agent interacts with skills through a single tool, `skill`, that handles
loads (Level 2 / Level 3) and on-demand creation:

- `skill(name: "<skill>")` — load the body.
- `skill(name: "<skill>", file_path: "references/...")` — load a bundled file.
- `skill(action: "create", name:, description:, body:)` — author a new skill
  (see [Creating skills](#creating-skills)).

It is a low-risk tool. For the full tool entry see **[docs/tools.md](tools.md#skill)**.

### Disabling skills

The whole tool is gated like any other tool by the `tools.skill` config flag
(opt-out — enabled unless explicitly set to `false`):

```yaml
tools:
  skill: false   # the agent can no longer load skills
```

Individual skills can also be toggled on/off (persisted in the `skill_states`
table, default-enabled) through any of three equivalent surfaces, all running
the same registry-validated write (`Skills::Toggle`):

- **In chat** — `/skills enable <name>` / `/skills disable <name>` (#188).
  Disabling the currently *active* skill also clears the pin (the assembler
  would silently drop a disabled skill, leaving a lying chip).
- **CLI** — `rubino skills enable|disable NAME`; `rubino skills list` shows the
  markers and `rubino skills show NAME` prints the `SKILL.md` body so you can
  review a skill before enabling it.
- **HTTP API** — `PUT /v1/skills/<name>` with `{ "enabled": false }` — see
  [docs/api/v1.md](api/v1.md).

Disabling a skill removes it from the Level-1 index, makes the tool return a
distinct "disabled" message if invoked by name, and blocks `/skills <name>`
activation until re-enabled.

Note: a bare `/skills <name>` does **not** enable or disable —
it activates one (next section), which is a different concept.

### Active skill (`/skills`)

On top of the model-driven 3-level disclosure, the *user* can pin one skill as
the session's **active skill** from interactive chat:

- `/skills` — list the available skills, with `(disabled)` and `(active)`
  markers.
- `/skills <name>` — activate `<name>`: its full body is **force-loaded into the
  system prompt every turn** (no `skill` tool call needed), until cleared or the
  process exits. Typing `/skills ` opens a dropdown picker of skill names (plus
  the `enable`/`disable` verbs), headed by a `✗ none` clear entry. A *disabled*
  skill is refused with a pointer to `/skills enable <name>`.
- `/skills none` (or picking `✗ none`) — clear the active skill:
  `✓ Cleared active skill (was: <name>).`

While a skill is active the status bar under the input shows it — `default · skill <name> · …` —
so you always know what extra instructions the model is carrying. A fresh
`rubino chat` boots with no active skill.

Activation respects the folder-trust gate: a project-local skill that lives in
an untrusted directory is refused with a reason (its `SKILL.md` would never be
injected), instead of showing an active chip with no effect.

**Activate vs enable/disable:** activating loads one skill's body into context
for *this session* (a per-session pin); enabling/disabling (the chat/CLI/API
toggle above) controls whether a skill exists in the Level-1 index *at all*,
for every session. They are independent surfaces.

### Skills vs custom commands

They look similar but trigger differently: a **skill** is loaded *by the model* when
it judges a task relevant (model-driven, via the `skill` tool), whereas a **custom
command** is invoked *by the user* with a slash command (user-driven). See
**[docs/commands.md](commands.md)** for custom commands.
