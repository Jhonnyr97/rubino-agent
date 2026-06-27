# Background shells as first-class background work (see / focus / stop)

Status: DESIGN (no implementation yet) · Branch: `feat/bg-shell-ux`

## Goal

Give a background **shell** the same user-facing affordances a background **subagent**
already has:

1. **See** it — a card + a picker row, at a glance.
2. **Focus** it — attach to a clear, live view of what it's doing.
3. **Stop** it — `/stop <id>` from the UI.

Today a background shell lives ONLY in `ShellRegistry`, so it is invisible to every
user surface. The model can read/tail/kill it via tools (`shell_output`,
`shell_tail`, `shell_kill`), but the human has no card, no picker entry, no attach,
no `/stop`.

## The central reuse lever (why this is mostly DRY, not new UI)

Three UI surfaces and the control handlers all read **one source of truth**:

- `UI::CLI#set_subagent_cards` → `BackgroundTasks.instance.running` (`cli.rb:930`)
- `UI::AgentMenu` picker entries default → `BackgroundTasks.instance.running` (`agent_menu.rb:21`)
- `BottomComposer` card host → `BackgroundTasks.instance.running` (`bottom_composer.rb:1639`)
- `/agents`, `/stop`, `auto_resolve_pending` → `BackgroundTasks` lookups

None of these inspect `subagent`/`runner` to decide whether to show a row — they
filter purely on `live_status?` (`LIVE_STATUSES = %i[running needs_approval stopping]`).

**So: anything in `BackgroundTasks#running` automatically gets a card, a picker row,
and `/stop`.** The whole feature reduces to *register the shell as a `BackgroundTasks`
entry* + a few thin, kind-aware branches.

## Architecture

Add a `kind: :subagent | :shell` discriminator to `BackgroundTasks::Entry`
(`background_tasks.rb:60`). A background shell gets BOTH:

- its existing `ShellRegistry::Entry` (process group, output ring, kill, stdin) — unchanged;
- a NEW linked `BackgroundTasks::Entry` (`kind: :shell`) that carries the SAME `bg_*`
  id, so the card/picker/stop surfaces light up and `/stop bg_x` already matches
  `shell_kill`'s id.

The two entries are bridged 1:1 by id. `ShellRegistry` stays the process owner;
`BackgroundTasks` becomes the *presentation + control* layer (as it already is for subagents).

```
ShellRegistry::Entry  ──(same bg_ id)──  BackgroundTasks::Entry(kind: :shell)
  pgid, pipes, buffer                      status, card, picker row, /stop
  read_new / write_input / kill            attach view, completion notice
```

### Reuse AS-IS (the shared seams — no shell-specific code)

1. `BackgroundTasks#running` + `live_status?` / `LIVE_STATUSES` — the liveness oracle
   that auto-drives cards + picker + composer.
2. `UI::SubagentCards` row rendering — reads only plain struct fields
   (`id, status, tool_count, started_at, prompt`); map `prompt`→command.
3. `UI::AgentMenu` row rendering — reads only `id, subagent, status, budget_request`.
4. `InputQueue#push_notice` → idle `coalesced_resume` (#561) — shells ALREADY ride
   this (`shell_registry.rb:372`).
5. `render_agent_output_tail` / `watch_loop` (`agents.rb:300-328`) — an existing
   kind-agnostic byte-tail renderer, perfect for the shell attach view.
6. `stop_entry` (`background_tasks.rb:456`) as the single stop entry-point, dispatched by kind.

### Thin shell adapters (the only new code — kept minimal)

1. **Bridge (register + sync).** In `shell_tool.rb#spawn_background` (`:382`), after
   `ShellRegistry.spawn`, `reserve` a `kind: :shell` `BackgroundTasks` entry with the
   same id. In `ShellRegistry#notify_completion` (`:357`), flip the linked entry to
   `:completed`/`:failed` via `complete` (so the card/picker drop it). Status for a
   shell is DERIVED (`ShellRegistry#status` from `wait_thr`); the bridge keeps the
   stored `BackgroundTasks` status in sync — single sync point at completion + an
   optional poll for the live `tool_count`/activity proxy (bytes/lines).
2. **Attach branch.** In `chat_command.rb#attach_agent_view` (`:3009`), branch on
   `kind == :shell`: `entry.messages` is empty (no session), so skip session replay
   and instead render the captured buffer + a polling `read_new` live-tail (reuse the
   `watch_loop` shape). Attached plain text → `ShellRegistry.write_input` (stdin),
   not `steer_agent`.
3. **Stop branch.** In `stop_entry` (`:456`), branch on `kind == :shell`:
   `Process.kill` the pgid (reuse `ShellKillTool`'s SIGTERM → grace → SIGKILL body,
   extracted to a shared `ShellRegistry#signal_group`) instead of `runner.cancel!`.

### Kind-aware copy (cosmetic, one helper)

`AgentMenu` header/hints ("subagents", "Enter attaches"), `SubagentCards` glyph
wording, and `Agents` copy ("No background subagents") hardcode "subagent". Introduce
ONE `entry_kind_label(entry)` → "subagent"/"shell" used by the picker header + card +
list copy, so a shell row reads right without forking the renderers.

## Lifecycle & the two-lifetime rule

A shell has TWO decoupled lifetimes, by design:

- The `BackgroundTasks` entry goes **terminal** (drops from `running`/cards/picker) the
  moment the shell exits — so the UI stops showing a dead shell as live.
- The `ShellRegistry` entry stays **retired** (RETIRED_TTL) so `shell_output` can still
  fetch the final output for the model.

Keep them decoupled: completion flips the BackgroundTasks status; retirement is
ShellRegistry-only.

## Open decisions (need your call)

- **D1 — id namespace.** Recommend the shell's `BackgroundTasks` entry **keep its `bg_*`
  id** (so `/stop bg_x` == `shell_kill bg_x`, one id the user sees everywhere). (Alt:
  give it `sa_*` — rejected, splits the id space.)
- **D2 — attach interactivity (scope).** v1 attach = **read-only live tail**; OR v1
  also routes attached plain-text to the shell's **stdin** (interactive bg process).
  stdin-steer is a nice win but more surface to test.
- **D3 — steer/probe on a shell.** Disable for `kind: :shell` (a shell has no model to
  probe / no steer queue), OR repurpose steer→stdin (ties to D2).

## Proposed slices (incremental, each independently testable)

- **Slice 1 — SEE + STOP.** `kind` discriminator + bridge (register/sync) + `stop_entry`
  shell branch + kind-aware label. Outcome: a bg shell shows a card + picker row and
  `/stop bg_x` kills it. (Biggest value, smallest surface — pure reuse + 2 thin branches.)
- **Slice 2 — FOCUS.** `attach_agent_view` shell branch: clear + buffer + polling tail.
  Outcome: Enter on a shell row attaches to a live output view; `←`/`/back` returns.
- **Slice 3 — stdin (optional, D2/D3).** Attached plain-text → `shell_input`.

Each slice: clean-code, DRY (reuse the named seams), spec'd, verified in the QA
container with a real bg shell (tmux: card visible, `/stop` kills, attach tails live).

## Non-goals (v1)

Reworking `ShellRegistry`'s process model; per-shell resource limits; persisting shell
output to a session Store (shells stay buffer-backed, not transcript-backed).
