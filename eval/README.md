# rubino A/B evaluation harness

A self-contained, **generic** A/B harness for the rubino coding agent. Given a
feature **toggle** (any dotted config key) and a fixed task suite, it runs each
task **N times** with the toggle **OFF** and **ON** against a fresh isolated
workspace, auto-checks success, captures cost metrics from rubino's structured
output, and prints an A/B comparison table.

The toggle is a *parameter*, so the same harness proves whether **any** feature
helps — `compression.enabled`, a caching flag, an edit-tool change, etc. The
harness treats rubino as a **black box**: it only runs `exe/rubino` and parses
its JSON output. It never touches rubino's runtime code or the user's config.

## Quick start

```bash
# From the repo root. Needs a working rubino model (the harness clones your
# ~/.rubino config + .env, so whatever model `rubino chat` uses, this uses).

# Demo on an inert flag (proves the runner + checks + table end-to-end):
ruby eval/run.rb --flag display.runtime_footer.enabled --on true --off false -n 2

# A/B a real feature flag:
ruby eval/run.rb --flag compression.enabled --on true --off false -n 3

# One task, faster iteration:
ruby eval/run.rb --flag compression.enabled -n 2 --only fix_bug,add_method
```

### CLI options

| flag | meaning | default |
|------|---------|---------|
| `--flag KEY` | dotted config key to toggle (e.g. `compression.enabled`) | `display.runtime_footer.enabled` |
| `--on VALUE` | ON value, parsed as a YAML scalar (`true`/`3`/`"x"`) | `true` |
| `--off VALUE` | OFF value | `false` |
| `-n`, `--repeats N` | repeats per task per arm (keep small — bounds cost) | `2` |
| `--only IDS` | comma-separated task ids to run | all |
| `--timeout S` | per-run wall-clock kill | `300` |
| `--source-home DIR` | real rubino home to clone config/.env from | `~/.rubino` |

Output: a per-run trace, an A/B table, and a raw `eval/results/<timestamp>.json`.

## Layout

```
eval/
  run.rb                 # the runner CLI (orchestration)
  lib/eval/
    task.rb              # Task struct + YAML loader
    workspace.rb         # isolated temp RUBINO_HOME + fixture copy + toggle injection
    rubino_runner.rb     # spawns rubino, parses stream-json into metrics
    checker.rb           # runs a task's success shell command (exit 0 = pass)
    report.rb            # aggregation (mean/min/max/stddev) + A/B table
  tasks/tasks.yml        # the task suite
  fixtures/<task>/...    # fixture projects copied fresh per run
  results/               # generated result JSON (gitignored)
```

## How a task + check is defined

Tasks live in `eval/tasks/tasks.yml`. Each entry:

```yaml
- id: add_method            # unique id (used in the report + filenames)
  kind: edit                # edit (strong, file-based check) | find (weak, answer keyword)
  fixture: add_method       # dir under eval/fixtures/ copied fresh per run; ~ for none
  prompt: >                 # the instruction sent to rubino (chat -q)
    Add a `multiply(a, b)` method to lib/calculator.rb so the tests pass.
  check: "ruby -Itest -Ilib test/calculator_test.rb"   # exit 0 = PASS, run in the workspace
```

Two kinds:

- **`edit`** — the agent changes files; the check is a **deterministic** shell
  command (run a test, `grep` for an inserted symbol). This is the **strong**,
  reliable signal.
- **`find`** — read-only navigation ("which file defines X?"). The runner writes
  the agent's final answer to `RESULT.txt` in the workspace, so the check can
  `grep RESULT.txt`. This is a **weak, lower-confidence** signal: the model can
  give a correct answer in a form the keyword misses (use a forgiving suffix
  match, not a strict full-path match).

### Add a task

1. (optional) Drop a fixture project under `eval/fixtures/<name>/` — a few files
   plus a check target (a failing test, or a file to grep). Fixtures are *input*
   and are excluded from rubocop.
2. Append an entry to `eval/tasks/tasks.yml`.
3. Sanity-check the check fails on the *unmodified* fixture and passes once the
   intended change is made (so a PASS means the agent really did the work).

## How the toggle is injected

For every run, `Workspace`:

1. Creates a throwaway temp root with its own `RUBINO_HOME` (rubino's single
   source of truth for where config/.env/db live — see
   `lib/rubino/config/loader.rb`).
2. Copies the user's real `~/.rubino/config.yml` into it (so the model /
   provider / api-key actually resolve) and **deep-sets the toggle key** to the
   arm's value (`flag_path.split(".")` → nested hash). The user's own config is
   **never mutated**.
3. Copies `~/.rubino/.env` in, so `${MINIMAX_API_KEY}` (and friends) still
   interpolate.
4. Copies the task fixture into a fresh working directory.

rubino runs there with `RUBINO_HOME` pointed at the temp home and the cwd set to
the fixture copy. After the run the whole temp root is removed. Edit tasks never
pollute each other or the repo's tracked fixtures.

## What metrics are captured, and from where

We run `rubino chat --output-format stream-json --yolo --new -q "<prompt>"` and
parse the JSONL (schema: `lib/rubino/output/result_serializer.rb`):

| metric | source | notes |
|--------|--------|-------|
| success | the task's `check` exit code (+ run `is_error`) | ground truth |
| `num_turns` (model-calls) | `result` frame | round-trip proxy (coarse) |
| `tool_calls` | tallied `tool_use` blocks across `assistant` frames | finer round-trip proxy |
| `duration_ms` | `result` frame | rubino's own turn clock |
| `wall_clock_s` | measured by the harness (`CLOCK_MONOTONIC`) | true end-to-end incl. spawn |
| `output_tokens` | `result.usage` | reliable |
| `input_tokens`, `cache_read` | `result.usage` | **see gap below** |
| `total_cost_usd` | `result` frame | null when input tokens are 0 |

### Honest gaps (verified on the MiniMax backend)

- **Input / cache tokens are unreliable.** The MiniMax proxy this repo uses
  often reports `input_tokens: 0` and never reports `cache_read_input_tokens`,
  so `total_cost_usd` comes back `null`. The harness surfaces whatever the
  provider gives but leans on **`output_tokens`, `num_turns`, `tool_calls`, and
  `wall_clock_s`** as the dependable cost signals. On a backend that *does*
  report input/cache tokens (e.g. native Anthropic), those columns populate and
  become the headline metric for a compression/caching A/B.

## Handling LLM non-determinism

The model is non-deterministic, so a single run proves nothing. The harness:

- runs each task **N times per arm** (`-n`), and
- reports **mean + min/max + stddev** per metric, plus the per-arm spread block.

Read the table with the spread in mind: a small mean delta swamped by a large
stddev (e.g. one outlier-slow model response) is **noise**, not a real effect.
Increase `N` to tighten the means when a delta looks marginal. For an *inert*
flag the success rate should match exactly and any token/time delta is pure
variance — that's the expected "no effect" baseline.

## How to grow this

- **More tasks.** Add edit fixtures across more change-shapes (multi-file edits,
  refactors, larger files that actually exercise compression). The edit/strong
  checks are where the signal is — prefer them over find/weak tasks.
- **Sturdier success-checkers.** Find-tasks are keyword-fragile; consider an
  LLM-judge fallback for "did the answer name the right thing" while keeping the
  deterministic shell check as the primary gate.
- **Compression-specific metrics.** When A/B-ing `compression.enabled`, parse
  rubino's `compression.*` log/SSE events (drill-in rate, summary token count,
  bytes saved) from the run and fold them into `report.rb` as extra columns, so
  you measure not just "did it cost less" but "how often did the model have to
  re-read compressed-away output" (the real compression risk).
- **Significance.** With enough N, add a simple bootstrap/CI around the deltas so
  the verdict line reads "ON better (p<0.05)" instead of a bare arrow.
```
