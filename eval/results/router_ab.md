# End-to-end A/B — unified compression router (oMLX, real rubino CLI)

Model: `Qwen3.6-35B-A3B-MLX-8bit` · server `http://127.0.0.1:8000/v1` (gateway
provider, api_key `fake`). Isolated `RUBINO_HOME` cloned from a dedicated oMLX
config (never `~/.rubino`). Flag toggled: `tool_output_compression.enabled`
(OFF=false, ON=true); the `logs` sub-flag is on in both the ON config so ON
exercises the full router. `input_tokens` is trustworthy on oMLX (the provider
reports prompt tokens; MiniMax does not). N=3 per task per arm.

## Per-task input tokens (mean), tool-calls, wall-clock, success

| Task | Arm | input tok | tool-calls | wall s | pass |
|---|---|---:|---:|---:|---|
| add_method | OFF | 40447 | 5.0 | 18.4 | 3/3 |
| add_method | ON  | 41249 | 5.0 | 20.7 | 3/3 |
| fix_bug | OFF | 40511 | 5.0 | 21.3 | 3/3 |
| fix_bug | ON  | 35546 | 4.3 | 22.6 | 3/3 |
| fix_inventory (run1) | OFF | 49382 | 5.0 | 37.5 | 3/3 |
| fix_inventory (run1) | ON  | 57919 | 5.7 | 45.0 | 3/3 |
| fix_inventory (run2) | OFF | 56753 | 5.7 | 28.2 | 3/3 |
| fix_inventory (run2) | ON  | 50428 | 5.0 | 28.6 | 3/3 |
| report_failure | OFF | 17721 | 1.0 | 13.9 | 3/3 |
| report_failure | ON  | 18040 | 1.0 | 15.6 | 3/3 |

## Aggregate (run2: fix_inventory + report_failure, 6 runs/arm)

| metric | OFF | ON | Δ (on−off) |
|---|---:|---:|---:|
| success rate | 100% | 100% | 0pp |
| mean input tok | 37237 | 34234 | **−3003 (−8%)** |
| mean output tok | 428 | 377 | −51 |
| mean tool-calls | 3.3 | 3.0 | −0.3 |
| mean wall-clock s | 21.0 | 22.1 | +1.1 |

## Honest reading

- **Success: 12/12 OFF and 12/12 ON across both runs — compression never broke a
  task.** Critically, every `report_failure` ON run still recovered the single
  `STEP 87 FAILED` line out of a 260-line log, so fidelity held end-to-end.
- **The token deltas on these short, edit-style tasks are within run-to-run
  noise.** `fix_inventory` swings ON-worse in run1 and ON-better in run2 — the
  variance is driven by how many tool-calls the model happens to make, not by
  compression. The dominant input cost on every run is the fixed system prompt +
  ~26 tool schemas (~17–20k tokens), which compression doesn't touch.
- **`report_failure` ON is slightly HIGHER (+319).** The synthetic uniform-INFO
  log (260 identical "passed ok" lines + one FAILED) hits the LogCompressor's
  `insufficient_saving` guard and is sent verbatim — so ON only pays the few
  tokens the `compress` schema param adds to the read/shell descriptions. This is
  the compressor's existing heuristic, faithfully preserved by the router (NOT a
  router regression): it compresses structured test/lint output, not flat logs.
- The trustworthy token signal is the **per-type deterministic eval**
  (`router_per_type.md`): 97% on a real rspec suite, 27% on a whole-file Ruby
  read, and **byte-identical passthrough on diff / grep / short**. The CLI A/B
  confirms the seam fires end-to-end (verified: a 120-line shell dump came back
  to the model as a marker + a `read <spill>` pointer, original spilled intact)
  and never costs correctness; the token win materializes on the large,
  structured outputs the per-type eval isolates.
