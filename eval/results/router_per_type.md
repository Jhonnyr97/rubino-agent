# Per-type routing — token measurement (oMLX, exact prompt_tokens)

Model: `Qwen3.6-35B-A3B-MLX-8bit` · server `http://127.0.0.1:8000/v1` · chat-template overhead subtracted (10 tok).
Router: `Rubino::Compression::ContentRouter` (the unified seam).

| Output | Routed → | Correct? | Full tok | Routed tok | Reduction | Passthrough byte-identical |
|---|---|---|---:|---:|---:|---|
| rspec suite (21 failures) | log (log) | ✅ | 126727 | 3791 | 97.0% | — |
| rubocop (750 files) | log (log) | ✅ | 1442 | 1285 | 10.9% | — |
| git diff -U25 (large, 9 files) | diff (diff) | ✅ | 16772 | 9791 | 41.6% | — |
| package-lock.json diff | diff (diff) | ✅ | 11591 | 76 | 99.3% | — |
| small diff (version bump) | diff (passthrough) | ✅ | 103 | 103 | 0.0% | YES ✅ |
| grep defs (50 hits) | grep (passthrough) | ✅ | 1089 | 1089 | 0.0% | YES ✅ |
| code whole-file read | code (skeleton) | ✅ | 8321 | 6070 | 27.1% | — |
| short output (3 lines) | short (passthrough) | ✅ | 7 | 7 | 0.0% | YES ✅ |
| gh api issues (100, uniform) | json (json) | ✅ | 13052 | 7833 | 40.0% | — |
| kubectl pods (100, +err/outlier) | json (json) | ✅ | 10117 | 4538 | 55.1% | — |
| docker inspect (1 big object) | json (json) | ✅ | 4939 | 573 | 88.4% | — |
| small JSON (health check) | json (passthrough) | ✅ | 41 | 41 | 0.0% | YES ✅ |

Routing: every fixture routed to the expected strategy. ✅
Passthrough fidelity: every passthrough output is byte-identical to its input. ✅

## JSON fidelity (byte-level, no LLM)

| Check | Result |
|---|---|
| lossless fold keeps the error row (`CrashLoopBackOff`) | ✅ |
| lossless fold keeps the outlier (`restarts: 9999`) | ✅ |
| lossless fold ratio | 62.6% |
| LOSSY (forced) STILL keeps the error row | ✅ |
| LOSSY STILL keeps the outlier | ✅ |
| LOSSY drops the rest behind `{"_elided": N}` | ✅ |
| LOSSY ratio (kept 5 rows) | 97.4% |
| small JSON passes through byte-identical | ✅ |
