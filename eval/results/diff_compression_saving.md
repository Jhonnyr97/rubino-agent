# Diff compression — token measurement (oMLX, exact prompt_tokens)

Model: `Qwen3.6-35B-A3B-MLX-8bit` · server `http://127.0.0.1:8000/v1` · chat-template overhead subtracted (10 tok).
Compressor: `Rubino::Compression::DiffCompressor` (deterministic, no ML).

| Diff | Strategy | Full tok | Compressed tok | Reduction | Fidelity invariant |
|---|---|---:|---:|---:|---|
| large source diff (git diff -U25, 9 files) | compressed | 16772 | 9791 | 41.6% | HELD — 575/575 +/- lines, 13/13 hunks, 9/9 file headers |
| lockfile diff (package-lock.json, 60 bumps) | compressed | 11591 | 76 | 99.3% | HELD — 1/1 file headers + generated summary (body elided by design) |
| small normal diff (version bump) | passthrough (too_small) | 103 | 103 | 0.0% | HELD — byte-identical (passthrough: too_small) |

**Mean reduction (compressed diffs only): 70.5%**

Fidelity: every +/- line + header survived (and the small diff is byte-identical). ✅
