# Agents & Subagents

rubino has two distinct multi-agent surfaces. Only the first one ships today:

1. **Background subagents** (✅ shipping) — the agent delegates bounded sub-tasks
   to isolated subagent runs via its `task` tool, and you supervise them with
   `/agents` and `/reply`. This is the surface you will actually use.
2. **Primary-agent switching** (⏳ not yet wired) — Tab-cycling between primary
   agents and `@mention` routing. The machinery exists (`Agent::Router`,
   `Agent::Definition`, `AgentRegistry`) but no call site passes an agent
   definition yet, so the default (build) agent handles every turn. See
   [the last section](#planned-primary-agent-switching--mentions-not-yet-wired).

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
`background: false` runs the child inline instead (the parent blocks).

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
| `✓` | done | Finished; result available | `/agents <id>` |
| `✗` | failed | Errored; error available | `/agents <id>` |

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
are live as `task` targets; the two *primary* agents are only reachable as the
default (`build`) or via the plan **mode** (`/mode plan`), not via agent
switching; the *utility* agents are internal.

| Agent | Type | Access | Description |
|-------|------|--------|-------------|
| **build** | primary | Full tools | Default development agent. Handles every turn today. |
| **plan** | primary | Read-only | Analysis/planning definition (the shipping read-only surface is `/mode plan`). |
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

## Planned: primary-agent switching & @mentions (not yet wired)

> **Status:** the machinery exists — `Agent::Router` (@mention detection,
> Tab-cycling, default routing) and the `agent_definition:` plumbing through the
> runner — but **no call site passes an agent definition**, so Tab and
> `@explore`/`@plan`/`@general` mentions currently do nothing. Use the
> background-subagent surface above for real work.

The intended design: press **Tab** to cycle through primary agents, or route a
single message with an `@mention`:

```
you > @explore Where is the database connection configured?
you > @plan How should we restructure the auth module?
```
