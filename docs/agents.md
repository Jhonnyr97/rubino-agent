# Agents & Subagents

rubino has two distinct multi-agent surfaces, and **both ship today**:

1. **Background subagents** (✅ shipping) — the agent delegates bounded sub-tasks
   to isolated subagent runs via its `task` tool, and you supervise them with
   `/agents` and `/reply`.
2. **Primary-agent switching** (✅ shipping) — pick the primary agent that
   handles your turns: `/agent <name>` (or a bare `/<name>` for a primary)
   pins it for the session, **Tab** cycles through the primaries, and a one-shot
   `/<name> <message>` routes a single message to any agent. The selected agent's
   Definition (its system prompt and tool scope) is threaded into the runner each
   turn, so the choice actually changes the model's persona/tools. See
   [Primary-agent switching](#primary-agent-switching) below.

> **Channels are cleanly separated:** `@` is the **workspace file** picker
> (`@path/to/file`), and `/` is the **agent/command** channel. There are no
> `@mention` agent routes — a filename like `@explore.rb` is always a file, never
> an agent. Use `/explore`, `/plan`, etc. to reach an agent.

---

## Background subagents (what ships)

### How they start

The MODEL spawns subagents with the `task` tool — you don't start them by hand;
you ask for something parallelizable ("audit these 4 files in parallel") and the
agent delegates. By default a `task` call runs in the **background**: it returns
immediately with a task id (`sa_…`) and the subagent works on its own thread
while the parent keeps going. When it finishes, the parent is notified with a
`[background-task] <id> completed` message folded into its turn; the parent can
also poll with `task_result(<id>)` or cancel with `task_stop(<id>)`.
`background: false` runs the child inline instead (the parent blocks); it goes
through the same nesting caps and ownership stamping as a background spawn.

Each subagent is **isolated**: it gets a fresh session seeded with ONLY the
prompt string — the parent transcript never leaks into the child, so the parent
must put every needed file path / error / detail into the prompt.

Built-in subagents the model can delegate to:

| Subagent | Access | Description |
|---|---|---|
| **explore** | Read-only tools | Fast codebase search and navigation (max 20 turns) |
| **general** | Full tools | Complex multi-step tasks (max 50 turns) |

Background subagents live only in the current process (nothing is persisted —
they die with the CLI/server process).

### Nesting and caps

Subagents keep the `task` tool, so a subagent CAN spawn its own subagents.
The tree is bounded in one place (`Tools::BackgroundTasks#reserve`) by three
config caps; when one is hit, the spawn is refused with a reason-specific
message instead of fanning out unbounded work:

| Config key | Default | Meaning |
|---|---|---|
| `tasks.max_depth` | `2` | Max nesting depth (human → child → grandchild) |
| `tasks.max_children_per_node` | `3` | Max live children per parent |
| `tasks.max_concurrent_total` | `8` | Max live subagents across the whole tree |

### Statuses

`/agents` and the live cards show each child's state:

| Glyph | Status | Meaning | You act via |
|---|---|---|---|
| `●` | `running` | Working (last activity shown) | — |
| `●` | `needs_approval` | A child tool needs your approval | `/agents <id>` |
| `⛔` | `blocked_on_human` | Asked a question only YOU can answer (`ask_parent` escalated to the human) | `/reply <id> <answer>` |
| `◷` | `blocked_on_parent` | Asked its agent-parent a question — the PARENT MODEL answers (`answer_child`); not your job unless you choose to step in with `/reply` | (optional) `/reply <id>` |
| `◌` | `stopping` | Stop requested; unwinding at its next checkpoint | — |
| `✓` | `done` | Finished; result available | `/agents <id>` |
| `✗` | `failed` | Errored; error available | `/agents <id>` |
| `⊘` | `stopped` | Cancelled by you (`--stop`); blocked descendants unwound; tools that completed before the stop may have left side effects | `/agents <id>` |

A `⛔ N subagent waiting on you` marker persists until you `/reply`.

### Supervising from the CLI: `/agents` and `/reply`

```
/agents                       # list background subagents (status, tools run, activity)
/agents <id>                  # drill in: live watch while running, result/error when done
/agents <id> --stop           # cancel a running subagent (blocked descendants unwind too)
/agents <id> steer "note"     # park a note folded into the child's context at its next turn
/agents <id> probe "question" # ephemeral read-only peek — nothing is saved to the child
/reply <id> <answer>          # answer a child blocked on an ask_parent question
/reply                        # bare: list the subagents currently blocked on you
```

`/tasks` is an alias for `/agents`. Stopping a node cancels its descendants'
ask-gates too, so a blocking question anywhere in the subtree unwinds at once.

#### Attach to a subagent (agent-view)

The typed forms above work by id from anywhere, but the fastest way to focus on
one running child is to **attach**. At the idle prompt press `↓` to open the
subagent picker, arrow to one, and `Enter`:

- the screen switches to that agent's **own full timeline** — its tool calls and
  what it said, replayed from its session (not the bounded activity snapshot the
  picker used to show);
- the prompt becomes **scoped** to it: `sa_xxxx ❯`;
- while attached, just **type** to steer the running child (or answer it if it's
  blocked on you) — no id needed; `←` on the empty prompt (or `/detach`) returns
  to the main timeline.

So attaching makes `/agents <id> steer/probe` and `/reply <id>` redundant for the
focused child — they're the same operations, just addressed by id. Attach is a
between-turns action (it owns the screen): while a parent turn is still streaming
the picker's `Enter` toasts "attach when the turn ends" — attach once it's idle.

**steer** is a persistent course-correction: the note enters the child's context
at its next turn boundary and changes its trajectory.
**probe** is ephemeral: a read-only side-inference over a snapshot of the
child's transcript; the answer is shown to you and discarded — nothing is
appended to the child's history.

### Parent↔child channels (model-driven)

The same three verbs are MODEL-callable tools, so an agent-parent can supervise
its own children the way you supervise yours. All are gated by `tools.task` and
**ownership-scoped at call time** — a caller can only touch its own direct
children (see [tools.md](tools.md) for parameters):

- **`steer(task_id, note)`** — park a persistent note on one of your running
  children; it folds into the child's context at its next turn.
- **`probe(task_id, question, live:)`** — check on a child without disturbing it.
  `live: false` (default) is a FREE registry snapshot (status, tool count, last
  activity, recent lines); `live: true` is a billed one-shot model peek over the
  child's transcript, budgeted per child (`tasks.max_live_probes_per_child`,
  default 5).
- **`ask_parent(question, blocking:)`** — the child→parent escalation (only
  available to subagents). `blocking: false` (default) keeps the child working
  and folds the answer in later; `blocking: true` parks the child until answered,
  bounded by `tasks.ask_parent_timeout` (default 900s — on expiry the child
  proceeds with its best judgement instead of hanging).
  Routing depends on who spawned the child: an agent-parent gets the question as
  a note and answers with `answer_child` (child shows `◷ blocked_on_parent`); a
  human-spawned child escalates straight to you (`⛔ blocked_on_human`, answered
  via `/reply`). A parent that cannot answer from its own context escalates by
  calling its OWN `ask_parent` — questions bubble up the tree to the human.
- **`answer_child(task_id, answer)`** — the agent-parent's `/reply`: delivers
  the answer into the asking child's context (unblocks a blocking ask, folds in
  for a non-blocking one).

### Approvals inside a background child

When a background child's tool needs human approval, the child parks and the
entry flips to `needs_approval` with the question/command shown on its card;
resolve it via `/agents <id>`. In `yolo` mode the usual approval-skip rules
apply (hardline floor still enforced — see [security.md](security.md)).

---

## Built-in agent definitions

These definitions exist in `Agent::AgentRegistry` today. The two *subagents*
are live as `task` targets; the two *primary* agents are switchable per session
(`/agent <name>`, a bare `/<name>`, or Tab — see
[Primary-agent switching](#primary-agent-switching)); the *utility* agents are
internal.

| Agent | Type | Access | Description |
|-------|------|--------|-------------|
| **build** | primary | Full tools | Default development agent (the registry default). |
| **plan** | primary | Read-only | Analysis/planning agent. Switch to it with `/agent plan`; `/mode plan` is the orthogonal read-only run **mode**. |
| **explore** | subagent | Read-only | Fast codebase search and navigation (`task` target). |
| **general** | subagent | Full tools | Complex multi-step tasks (`task` target). |
| **compaction** | utility | None | Internal: compresses context. Hidden. |
| **title** | utility | None | Internal: generates session titles. Hidden. |

### Custom agents (via code)

`AgentRegistry#register` accepts custom definitions programmatically:

```ruby
Rubino.agent_registry.register(
  Rubino::Agent::Definition.new(
    name: "security",
    type: :subagent,
    description: "Security-focused code review",
    system_prompt: "You are a security expert…",
    tools: %w[read grep glob],
    permissions: { "shell *" => "deny", "write *" => "deny" }
  )
)
```

A registered `:subagent` definition immediately becomes a valid `task` target
(it is advertised in the `task` tool's description). Each definition can carry
its own model, system prompt, tool list (`:all`, `:read_only`, or names),
pattern-based permission overrides (merged over the global rules by
`ApprovalPolicy`), MCP-server scoping, and a `max_turns` budget.

> **Note:** the `agents:` key in `config.yml` is reserved but **not yet read**
> by the registry — declaring custom agents in config has no effect today.

---

## Primary-agent switching

You choose which primary agent handles your turns. The pinned agent is a
process-level slot (`Rubino::ActiveAgent`, sibling to `Rubino::Modes`): a fresh
`rubino chat` boots on the registry default (`build`), and an explicit switch
takes effect for the rest of that process (no premature persistence). Switching
is entirely on the **slash** channel and **Tab** — there is no `@mention` agent
routing (`@` is the workspace file picker).

```
you > /agent plan          # pin a primary agent for the session
you > /plan                # bare /<name> — same, for a primary agent
you > <Tab>                # cycle through the primary agents, wrapping around
you > /explore Where is the database connection configured?   # one-shot route a single message
```

- **`/agent <name>`** (or a bare **`/<name>`** when `<name>` is a primary) pins
  the agent for the session. Only **primary** agents are switchable; subagents
  (`explore`/`general`) are never pinned.
- **Tab** cycles through the primary agents.
- **`/<name> <message>`** routes a single message to any agent (primary or
  subagent) without changing the sticky selection.

The selected agent's Definition — its system prompt and tool scope — is threaded
into the runner on every turn, so switching actually changes the model's
persona and the tools it can call, not just a cosmetic label.
