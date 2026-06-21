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

Routing: every fixture routed to the expected strategy. ✅
Passthrough fidelity: every passthrough output is byte-identical to its input. ✅
