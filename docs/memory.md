# Memory

rubino remembers facts about you and the project across sessions. The default backend is a small SQLite "tiny-Zep" store — Zep/Graphiti-inspired, minus the graph database, the server, and the multi-call pipeline.

## Backends

Memory backends are pluggable (registered like tools). Two ship:

| `memory.backend` | What it is |
|---|---|
| `sqlite` (**default**) | tiny-Zep: LLM-extracted atomic facts, bi-temporal supersession, hybrid FTS5/BM25 (+ optional vector) ranked recall, graph-lite 1-hop blend |
| `default` | the legacy non-ranked store (kept for back-compat) |

Switch backends:

```bash
rubino memory backend          # show the active backend + available names
rubino memory backend sqlite   # switch (writes memory.backend to config.yml)
```

The agent loop, the in-chat `/memory` view, the `/status` panel, the `rubino memory` CLI, and the HTTP `/v1/memory` operations all use the **active** backend (fixed in #94/#106/#83 — these surfaces previously read a hardwired legacy table and never saw the facts the agent actually persists).

## The sqlite tiny-Zep backend

### What's stored

One declarative **fact** per row. Facts carry a `kind` (`user_profile`, `preference`, `fact`, `project`, `env`, …), the source session, a confidence, optional entity tags, and bi-temporal validity columns (`valid_from` / `valid_to`).

- **User profile** (`user_profile` facts) — durable facts about you, metered against `memory.user_char_limit`.
- **Project context** (`project` / `env` facts) — facts about the codebase/environment.
- **General facts** — everything else.

### How facts are extracted (write path)

When `memory.auto_extract` is on, auto-extraction runs as a post-turn job (`ExtractMemoryJob` — executed immediately after the turn in the default inline jobs mode): a single auxiliary-LLM call looks at the recent turn and returns `{add, supersede}`:

- **add** — new atomic facts (deduplicated via a Jaccard near-dup check against the live set, no second LLM call).
- **supersede** — a contradicted fact is **soft-retired** (its `valid_to` is set and `superseded_by` points at the replacement), not deleted — temporal correctness without losing provenance (Graphiti-style edge invalidation collapsed to one call).

When extraction stores facts, the chat prints a deterministic confirmation from the write path (`✓ saved to memory · 2 facts (e6bf776b, a91c03d2)`) — the agent's "I'll remember that" narration alone is not a save signal.

Every write goes through the same injection-defense floor as the legacy store: a `ThreatScanner` (prompt-injection / exfiltration patterns) plus a character budget. A fact that trips a guard is skipped, not allowed to splice tainted/over-budget content into a future system prompt.

Two budgets, deliberately separate:

- `memory.memory_char_limit` (2200) / `memory.user_char_limit` (1375) — the **injection** budget: how much is packed into the prompt at retrieval time.
- `memory.ingest_char_limit` (null = unbounded) — the **store** budget: storing facts isn't throttled by the injection budget, so long multi-session conversations don't stall once the injection budget fills.

### How facts are recalled (read path)

`retrieve` runs a **hybrid ranked** recall over LIVE facts (`valid_to IS NULL`):

1. **Direct relevance** — FTS5/BM25 over the query (and vector KNN when enabled), fused with Reciprocal Rank Fusion and lightly kind-weighted (durable `user_profile`/`preference`/`env` facts win ties). These are the only content-matching signals, so the fact a keyword probe ranks #1 stays #1.
2. **Tail supplements** — graph (1-hop entity neighbours of the query) then recency only **backfill** the remaining budget after direct hits. They can never outrank a direct content match (this was the dominant cause of single-shot recall misses).

Results are greedily packed under the retrieval char budget. Common stopwords ("user", "project", "the", …) are excluded from the FTS MATCH so a probe doesn't match every fact on a trivial word.

### Tuning

```yaml
memory:
  sqlite:
    vector: false   # opt-in sqlite-vec / RubyLLM.embed KNN on top of FTS5 (off by default — no extra deps needed)
    graph: true     # graph-lite 1-hop entity/edge blend (on by default; set false to A/B the graph signal)
```

Vector mode requires both `vector: true` **and** `RubyLLM.embed` to be wired; otherwise it's FTS5-only.

## The `memory` tool

The agent persists facts autonomously via the `memory` tool (gated by `tools.memory`, on by default):

- `action: add` — record a new fact.
- `action: replace` — supersede an existing fact (`old_text` selects it).
- `action: remove` — hard-delete a fact.
- `target: user` writes the user profile; `target: memory` writes general memory.

The tool stores **one atomic fact per call** — separate facts go in separate calls so each can be superseded or forgotten independently. Every write is confirmed deterministically in chat by the tool-result line, e.g.:

```
✓ done · memory · Memory replaced (id=e6bf776b, kind=user_profile).
```

Content is scanned for injection/exfiltration patterns and subject to the character budget. Because this lets the agent write to its own future context, see [security.md](security.md#autonomous-memory) for the trust model.

## Inspecting and managing memory

```bash
rubino memory list             # most recent LIVE facts (active backend)
rubino memory list --all       # include superseded (soft-retired) facts
rubino memory list --kind user_profile --limit 50
rubino memory show <id>        # full fact incl. the temporal chain (id prefix accepted)
rubino memory delete <id>      # hard-delete
```

`list` and the in-chat `/memory` views show only **live** facts (`valid_to IS NULL`) — superseded facts are retained for provenance but hidden, so a contradicted fact is never presented as current and the header count always matches the rows. Pass `--all` to `rubino memory list` to see the supersession history; `rubino memory show <id>` prints a retired fact's `Retired:` / `Superseded by:` chain.

In-chat, `/memory` inspects, searches (`/memory <query>` or `/memory search <query>`), and forgets what the agent remembers. Both surfaces read the active backend.
