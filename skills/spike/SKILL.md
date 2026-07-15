---
name: spike
description: Use when you need to validate feasibility before committing to a real build — throwaway experiments, comparing approaches, surfacing unknowns. Triggered by "try this", "spike this", "is this even possible?", "compare A vs B", "prototype X".
version: 1.0.0
license: MIT
category: "Development"
---

# Spike — Throwaway Feasibility Experiments

Use this when you need to **feel out an idea** before committing to a real
build — validating feasibility, comparing approaches, or surfacing unknowns
that no amount of research will answer.

Spikes are disposable by design. Throw them away once they've paid their debt.

Load this when the user says things like "let me try this", "spike this out",
"is this even possible?", "before I commit to X", "quick prototype of Z", or
"compare A vs B".

## When to use

- "let me try this" / "spike this out" / "is this even possible?"
- Before committing to X — validate feasibility with a throwaway experiment
- "compare A vs B" — build quick variants to see which wins
- Surfacing unknowns that no amount of research alone will answer

## Don't use for

- The answer is knowable from docs or reading code — just do research, don't build
- The work is production path — switch to planning mode instead
- The idea is already validated — clarify requirements first, then plan the build

## Core Method

Every spike follows this loop:

```
decompose → research → build → verdict
    ↑________________________________↓
           iterate on findings
```

### 1. Decompose

Break the user's idea into **2–5 independent feasibility questions**. Each
question is one spike. Present them as a table with Given/When/Then framing:

| # | Spike | Validates (Given/When/Then) | Risk |
|---|-------|----------------------------|------|
| 001 | websocket-streaming | Given a WS connection, when LLM streams tokens, then client receives chunks <100ms | High |
| 002a | pdf-parse-lib-a | Given a multi-page PDF, when parsed with lib A, then structured text is extractable | Medium |
| 002b | pdf-parse-lib-b | Given a multi-page PDF, when parsed with lib B, then structured text is extractable | Medium |

**Spike types:**
- **standard** — one approach answering one question
- **comparison** — same question, different approaches (shared number, letter suffix `a`/`b`/`c`)

**Good spike questions** have specific feasibility with observable output. **Bad
spike questions** are too broad, have no observable output, or are just "read
the docs about X".

**Order by risk.** The spike most likely to kill the idea runs first. No point
prototyping the easy parts if the hard part doesn't work.

**Skip decomposition** only if the user already knows exactly what they want to
spike and says so.

### 2. Align (for multi-spike ideas)

Present the spike table. Ask: "Build all in this order, or adjust?"

Let the user drop, reorder, or reframe before you write any code.

### 3. Research (per spike, before building)

Spikes are not research-free — you research enough to pick the right approach,
then you build.

1. **Brief it.** 2–3 sentences: what this spike is, why it matters, key risk.
2. **Surface competing approaches** if there's real choice:

| Approach | Tool/Library | Pros | Cons | Status |
|----------|-------------|------|------|--------|
| … | … | … | … | maintained / abandoned / beta |

3. **Pick one.** State why. If 2+ are credible, build quick variants within the
   spike.
4. **Skip research** for pure logic with no external dependencies.

Use rubino's tools for research:
- `web_search("ruby websocket streaming libraries 2025")` — find candidates
- `web_fetch` the actual docs of the top candidates
- `shell("gem search websocket")` — check what's available
- For libraries without docs pages, clone and read their `README.md` / `examples/`

### 4. Build

One directory per spike. Keep it standalone under `.rubino/spikes/`:

```
.rubino/spikes/
├── 001-websocket-streaming/
│   ├── README.md
│   └── main.rb
├── 002a-pdf-parse-lib-a/
│   ├── README.md
│   └── parse.rb
└── 002b-pdf-parse-lib-b/
    ├── README.md
    └── parse.rb
```

**Bias toward something the user can interact with.** Spikes fail when the only
output is a log line that says "it works." The user wants to *feel* the spike
working. Default choices, in order of preference:

1. A runnable CLI that takes input and prints observable output
2. A minimal script the user can `ruby run` and see results
3. A unit test that exercises the question with recognizable assertions

**Depth over speed.** Never declare "it works" after one happy-path run. Test
edge cases. Follow surprising findings. The verdict is only trustworthy when
the investigation was honest.

**Avoid** unless the spike specifically requires it: complex gem management,
Docker, env files, config systems. Hardcode everything — it's a spike.

**Parallel comparison spikes (002a / 002b) — use subagents.** When two
approaches can run in parallel and both need real engineering (not 10-line
prototypes), fan out with rubino's subagents:

```ruby
# Each subagent builds one approach independently
task(subagent: "general",
     prompt: "Build 002a-pdf-parse-lib-a: spike testing PDF extraction with library A. …")
task(subagent: "general",
     prompt: "Build 002b-pdf-parse-lib-b: spike testing PDF extraction with library B. …")
```

Each subagent returns its own verdict; you write the head-to-head comparison.

### 5. Verdict

Each spike's `README.md` closes with:

```markdown
## Verdict: VALIDATED | PARTIAL | INVALIDATED

### What worked
- …

### What didn't
- …

### Surprises
- …

### Recommendation for the real build
- …
```

- **VALIDATED** — the core question was answered yes, with evidence.
- **PARTIAL** — it works under constraints X, Y, Z — document them.
- **INVALIDATED** — doesn't work, for this reason. This is a successful spike.

## Comparison Spikes

When two approaches answer the same question (002a / 002b), build them **back
to back**, then do a head-to-head comparison:

```markdown
## Head-to-head: lib_a vs lib_b

| Dimension | lib_a (002a) | lib_b (002b) |
|-----------|-------------|-------------|
| Extraction quality | 9/10 structured | 7/10 table-only |
| Setup complexity | gem install, 1 line | gem install + system dep |
| Perf on 100-page PDF | 3s | 18s |
| Handles rotated text | no | yes |

**Winner:** lib_a for our use case. lib_b if we need table-first extraction
later.
```

## Frontier Mode (what to spike next)

If spikes already exist and the user says "what should I spike next?", walk
the existing directories and look for:

- **Integration risks** — two validated spikes that touch the same resource but
  were tested independently
- **Data handoffs** — spike A's output was assumed compatible with spike B's
  input; never proven
- **Gaps in the vision** — capabilities assumed but unproven
- **Alternative approaches** — different angles for PARTIAL or INVALIDATED
  spikes

Propose 2–4 candidates as Given/When/Then. Let the user pick.

## Output

- Create `.rubino/spikes/` in the project root
- One dir per spike: `NNN-descriptive-name/`
- `README.md` per spike captures question, approach, results, verdict
- Keep the code throwaway — a spike that takes 2 days to "clean up for
  production" was a bad spike

## Common Pitfalls

1. **Building production code.** A spike is not a prototype that graduates to
   production. Throw it away. Rebuild properly with a real plan and tests.
2. **Declaring success too early.** One happy-path run is not a verdict. Test
   edge cases, error paths, and real-world inputs.
3. **Skipping the verdict.** Every spike must end with VALIDATED, PARTIAL, or
   INVALIDATED. Unjudged spikes are wasted effort.
4. **Spiking the easy parts first.** Order by risk — kill the idea early if it
   won't work.
5. **Over-engineering.** No config files, no CI, no linters. It's a spike.
   Hardcode everything.

## Attribution

Adapted from the Hermes Agent `spike` skill and the GSD (Get Shit Done)
project's `/gsd-spike` workflow — MIT © 2025 Lex Christopherson.
