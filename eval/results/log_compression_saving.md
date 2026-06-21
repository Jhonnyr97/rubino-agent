# Log compression — token measurement (oMLX, exact prompt_tokens)

Model: `Qwen3.6-35B-A3B-MLX-8bit` · server `http://127.0.0.1:8000/v1` · chat-template overhead subtracted (10 tok).
Compressor: `Rubino::Compression::LogCompressor` (deterministic, no ML).

| Output | Full tok | Compressed tok | Reduction | Fidelity invariant |
|---|---:|---:|---:|---|
| rspec (full suite, 21 failures) | 126727 | 3791 | 97.0% | HELD — 21/21 failure descriptors + tally |
| rubocop (750 files, 20 offenses) | 1442 | 1285 | 10.9% | HELD — 20/20 offenses + summary |
| git log --oneline -50 | 1204 | 232 | 80.7% | HELD — n/a (no failures) |
| git log --stat -15 | 5700 | 327 | 94.3% | HELD — n/a (no failures) |
| ls -R lib | 2061 | 110 | 94.7% | HELD — n/a (no failures) |

**Mean reduction (compressed outputs only): 75.5%**

Fidelity: every failure descriptor + summary survived in every output. ✅

## Interpretation

- **Test/build output is the high-ROI channel, confirmed on our data.** rspec
  hit **97%** — the headroom 85–94% claim holds (and is beaten) on a real full
  suite, because the 8.3k-line green progress section is pure noise and the
  signal (21 failures + the tally) is ~170 lines. The fidelity invariant held:
  all 21 failure descriptors, all 21 `Failure/Error:` bodies, and the
  `N examples, M failures` tally survived.
- **rubocop is the floor (10.9%)** — its output is ALREADY mostly the signal
  (one line per offense), so there is little noise to drop. Still a net win, no
  loss; fidelity held (20/20 offenses + summary).
- **`git log`/`ls` reduce a lot (80–95%) but the fidelity invariant is VACUOUS
  there** (no failures to anchor on). The compressor keeps only keyword-bearing
  / boundary lines and drops the rest — fine for the agent's "what happened"
  read, but for a directory listing or full history the model could miss a
  specific filename/commit. The retrieve pointer covers this (one
  `retrieve_output` away), but it argues for scoping the default-ON to
  TEST/LINT/BUILD commands rather than blanket every shell dump.
- Token method: exact `usage.prompt_tokens` from the local oMLX server,
  max_tokens:1, minus the measured 10-token chat-template overhead. Not a
  chars/4 estimate.
