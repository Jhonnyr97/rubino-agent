# agent.md — session state & decisions (handoff)

> Working handoff for the next agent. NOT the project guide — that's `AGENTS.md`.
> Branch: `test/pre-release-gate`.

## How this is run (no Docker)

- rubino runs from THIS checkout via `~/.local/bin/rubino-dev` (forces ruby
  3.4.7, `BUNDLE_GEMFILE` = this repo, does NOT change cwd → operates on the dir
  you invoke it from). Works anywhere on the machine; whatever is checked out
  here is what runs — no reinstall. The installed gem `0.4.0` is the OLD fallback
  WITHOUT our fixes — always verify with `rubino-dev`.
- LLM backend: local OpenAI-compatible server on `127.0.0.1:8000` = **`ds4-serve`**
  (DeepSeek: `deepseek-v4-flash`, `deepseek-v4-pro`). It **STREAMS tool-call
  argument deltas** (a file write is on the wire as it generates) AND round-trips
  `reasoning_content`. Config: `~/.rubino/config.yml` → `model.default:
  deepseek-v4-flash`, provider `gateway` (openai_compatible, base_url
  `127.0.0.1:8000/v1`).
  - ⚠️ **ds4-server is a SINGLE KV slot and has no auto-restart; it CRASHES under
    large generations.** If a "freeze" reappears, FIRST check it's still up:
    `curl -s 127.0.0.1:8000/v1/models`. Its log is `/tmp/ds4-server.log` — the
    single best diagnostic (see below).
- Verify TUI behavior in a REAL terminal (offline PTY/pyte capture misses
  raw-mode defects). The fastest objective probe is a PTY driver that timestamps
  stdout (scratchpad/pty_*.rb in past sessions) + tailing `/tmp/ds4-server.log`.

## The local-performance work — DONE + validated live (this branch)

The user's "freeze on the local config" was THREE distinct bugs. All fixed and
verified live against ds4 (see commits on this branch). Read
`~/.claude/.../memory/reference_rubino_kv_cache_bust_rootcause.md` +
`project_rubino_kv_cache_fix.md` for the full diagnosis.

1. **Cross-turn freeze = KV prefix-cache busting (#608b/#608c).** ds4 only reuses
   cache on a PURE prefix-extension (`common==live`); any divergence → full
   `ctx=0..N` re-prefill (grows with context = "freeze after N turns").
   - **Reasoning replay:** rubino dropped the assistant's `reasoning_content`, so
     the replay diverged from the server's KV where reasoning was generated.
     Now persisted (`metadata[:reasoning]`) and replayed as wire
     `reasoning_content` (Hermes conversation_loop.py:940 parity). Bug found:
     `extract_thinking` read `response.reasoning` (nonexistent) not `.thinking`.
     Files: loop.rb, ruby_llm_adapter.rb (normalize_intermediate/rebuild_thinking/
     load_history), session/message.rb. Effect: turn 2+ 21s → 0.6s.
   - **Aux off-slot gate:** post-turn memory-extraction/distill ran a divergent
     no-tools prompt on the SAME slot every turn → evicted the main KV. Now
     SKIPPED on the interactive REPL when the aux task resolves to the main
     endpoint (`Configuration#auxiliary_on_main_endpoint?`); extraction happens at
     session-end flush + compaction (no recall lost — the per-session memory
     snapshot is frozen anyway). `interactive` flag threaded build_runner(default
     true)→setup_oneshot(false)→Runner→Lifecycle. A DISTINCT aux endpoint keeps
     the inter-turn cadence. Files: configuration.rb, lifecycle.rb, runner.rb,
     chat_command.rb.

2. **Large-write freeze = dead UI past the preview cap (#608d).** ds4 streams a
   big `write`'s args for minutes; after the 30-line preview cap `tool_chunk`
   stopped emitting and the facet was hidden → ~38s of dead screen. Fix (cli.rb):
   `tool_params_feed`/`tool_chunk` stream the params IN FULL (`full: true`, no
   cap — the user watches the file land; the cap stays for tool OUTPUT) + an
   animated facet during arg streaming. Verified: full content shown, UI silence
   38s → 6.3s. NB the deltas are INCREMENTAL (not cumulative — no O(N²)); the
   model is just genuinely slow (~17-22 t/s, degrading) for big files.

3. **`ctx` gauge frozen during a run (#608e).** The bar repainted only at turn
   boundaries and read persisted messages. Fix: `chat_command#live_status_meter`
   captures the base once → cheap no-DB lambda on `ui.live_status_provider`; the
   cli ticker (`refresh_live_ctx_bar`, ~1/s) feeds it `@turn_tok_chars/4` and
   repaints. `build_status_line` refactored to share `render_status_bar`.
   Verified: ctx climbs 0k→1.2k during a write.

### Diagnostic playbook (reuse this)
- `/tmp/ds4-server.log`: `live kv cache miss … common=N reason=token-mismatch`
  then `chat ctx=0..N:N prompt done <s>` = a full re-prefill. `common==live` +
  `ctx=K..N:small done 0.6s` = a cache HIT (what you want). Within-turn tool
  iterations already hit; the bug is at turn boundaries.
- Repro multi-turn: `rubino-dev -q "…" --yolo` then `-c -q "…"` (one-shot
  continues a session) OR a PTY driver for true interactive multi-turn (the gate
  is REPL-only, so one-shot won't show the aux-eviction fix). `RUBINO_HOME=<tmp>`
  + a sed'd config isolates variables. A logging TCP proxy (:8999→:8000) captures
  request/response bodies to confirm delta-vs-cumulative and reasoning replay.

## Other uncommitted history folded into this branch's tip
- **Streaming tool-call params UX (#608):** `lib/rubino/ui/tool_args_stream.rb`
  (single-pass JSON streaming decoder, surfaces string VALUES), adapter
  `announce_tool_stream` (emits `:tool_preparing` + `:tool_args`), `api.rb`/`cli.rb`
  sinks, byte-batching in `stdout_proxy.rb`/`cli.rb`. The token/speed footer plan
  is now partly realized by the live `ctx` gauge (#608e); a tok/s readout is still
  open.
- **Per-turn SummarizeSessionJob removed:** the running summary is produced ONLY
  by threshold-gated compaction (Hermes/Claude-Code parity), never a background
  job every turn. Handler deleted; `auto_summarize` config + `memory_auto_summarize?`
  gone. (This ALSO removed one of the per-turn aux-LLM calls — aligned with #608c.)

## Backlog / NOT done
- **Fix C (prompt normalization + volatile-to-tail):** NOT needed (cache hits
  already land without it; the frozen snapshot keeps volatile_tail stable).
  Offered as optional strict-Hermes parity hardening only.
- **Large files are genuinely slow on ds4** (model throughput, not rubino). The
  UI now shows progress; making it FASTER is behavioral (steer toward edits /
  smaller writes) — not yet done.
- **tok/s readout** in the footer (the other half of the #608 token-footer plan).
- 5 PRE-EXISTING host rspec failures (ruby_tool load-path, fresh_home_db schema)
  — NOT regressions; see `reference_rubino_host_rspec_env_failures`.

## Constraints / protocol
- Clean code / DRY; refactor when it keeps things clean.
- Repo/commit/PR content in English. NO co-author / "Generated with" trailers.
- Verify with `rubino-dev` against live ds4 before claiming a TUI fix works
  (offline render misses raw-mode defects).

## Test status
Full suite green except the 5 pre-existing host failures above
(`6376 examples, 5 failures, 8 pending`). Rubocop clean on all touched files.
