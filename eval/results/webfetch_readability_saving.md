# webfetch: old strip_html vs readability extraction (token-honest)

Model `Qwen3.6-35B-A3B-MLX-8bit` on oMLX, exact `usage.prompt_tokens` (overhead 10 tok subtracted). Offline on saved fixtures, each truncated to MAX_BODY_SIZE=100000 then UTF-8 scrubbed (as the tool does).

| fixture | old tok | new tok | reduction | chars old→new | fallback | content kept | boilerplate dropped |
|---|--:|--:|--:|--:|:-:|:-:|:-:|
| wikipedia_ruby (article + heavy nav/footer) | 2829 | 1187 | 58.0% | 9296→4590 | no | yes | yes |
| docs_ruby_string (API docs page) | 11809 | 9489 | 19.6% | 43709→34583 | no | yes | n/a |
| hn_front (HARD: content in <table>, no <main>/<article>) | 1302 | 1319 | -1.3% | 3810→3779 | no | yes | n/a |
| thin_content_fallback (HARD: content NOT in <main>, chrome dominates) | 2239 | 2239 | 0.0% | 7206→7206 | fired | yes | n/a |

Fidelity asserts: `keep` substrings present in the NEW output, `drop` boilerplate absent; on the thin/chrome-dominated page the safety fallback must fire (NEW == full strip, nothing lost).
