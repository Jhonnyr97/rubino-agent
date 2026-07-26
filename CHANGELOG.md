# Changelog

## [Unreleased]

### Added

- **`formatters:` config is now wired up (was a 100% dead stub since 0.1.0).**
  `formatters: { "*.rb": "rubocop -A --fail-level=fatal" }` now actually runs:
  after a `write`/`edit` tool call successfully touches a file, the first
  matching glob's command runs with the file's absolute path appended as the
  trailing shell argument (shell-escaped), through the same OS write-jail
  every shell spawn uses. Synchronous and bounded (30s), so the on-disk
  content already reflects the formatted result when the call returns. A
  failing/timed-out formatter never fails the write/edit — it only appends a
  `[formatter] ...` note — and the session's read-tracker is refreshed with
  the real post-formatter bytes so a follow-up edit isn't spuriously refused
  as "changed on disk since last read". See `docs/configuration.md#formatters`.

- **`chat.auto_resume` config to opt out of bare-`chat` auto-resume.** A bare
  `rubino chat` (no `--new`/`--resume`/`--continue`) has resumed the most
  recent resumable session for the launch dir by default since #99; that
  default is now a documented config knob (`chat.auto_resume`, default
  `true`) instead of being hardcoded, so it can be turned off to always start
  fresh. Explicit `--resume`/`--continue`/`--session` are unaffected either
  way.

## [0.5.3] - 2026-07-26

### Added

- **Opt-in OpenTelemetry tracing** (`otel:` config, default OFF). With the
  optional `opentelemetry-sdk` + `opentelemetry-exporter-otlp` gems installed,
  rubino exports one trace per turn over OTLP http/protobuf following the OTel
  GenAI semantic conventions: `invoke_agent <agent>` per turn (subagent turns
  nest under their `task` call), `chat <model>` per model call — the whole
  retry/recovery/fallback envelope, with `gen_ai.usage.*` token counts
  including prompt-cache reads — and `execute_tool <name>` per tool call,
  approval gate included (`rubino.tool.status: success|error|denied`). Privacy
  by default: no message/tool text is exported unless `otel.capture_content`
  (or the standard `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true`)
  opts in, and even then payloads pass `Logger.redact` and are truncated.
  Zero-cost no-op when disabled; fail-open (a missing gem or broken exporter
  config logs one warning and disables itself). Also covered: auxiliary LLM
  calls (summarize/title/vision/approval) as `chat` spans tagged
  `rubino.aux.task`, and the turn-opening memory recall as a `search_memory`
  span with a relevant-memories count; the post-turn background review
  (memory extraction + skill capture) traces as its own `invoke_agent` run.
  The `execute_tool` span carries the always-on audit skeleton:
  `rubino.tool.decision.source` (which mechanism allowed/denied the call —
  `auto`/`user`/`policy`/`hardline`/`permissions: deny`/`doom-loop`/
  `no interactive session`) and `rubino.tool.target` (the skill/subagent
  name for `skill`/`task` calls). See `docs/observability.md`.

### Changed

- **Subagent management collapsed into one `task_manage` tool.** The four tools
  `task_result` / `task_stop` / `steer` / `probe` are replaced by a single
  `task_manage(id:, action:, note:, question:, live:)` with `action` ∈ `result` |
  `stop` | `steer` | `probe` (`result` keeps the list-all-when-no-id behaviour;
  `steer` takes the `note`; `probe` keeps both paths — the free non-disturbing
  snapshot and, with `live:true`, the billed one-shot `question` peek budgeted per
  child) — mirroring the
  `shell_manage` collapse and Hermes' single delegate + manage surface. Approval
  is **per-action**: `result`/`steer`/`probe` run unprompted, while `stop` is
  gated exactly as the old medium-risk `task_stop` was. The `stop`/`steer`/`probe`
  actions are ownership-scoped (you can only manage your own direct children);
  `result` stays unscoped (its list-all is the `/tasks` view). `task`'s
  background-launch message and completion notice now point at `task_manage`.
  Built-in tool count drops from 22 to 19 (config-group rows stay 17 — the whole
  delegation family already shared `tools.task`).
- **Background-shell management collapsed into one `shell_manage` tool.** The
  four tools `shell_output` / `shell_tail` / `shell_input` / `shell_kill` are
  replaced by a single `shell_manage(run_id:, action:)` with `action` ∈
  `output` | `tail` | `input` | `kill` (`output` keeps the `mode: new|all`
  behaviour; `input` keeps `enter`/`eof`; `tail` keeps `timeout`) — mirroring
  Hermes' single `process(action:)`. Approval is **per-action**: `output`/`tail`
  are read-only and run unprompted, while `input`/`kill` are gated exactly as
  the old medium-risk tools were. `shell`'s background-launch message and the
  completion notice now point at `shell_manage`. Built-in tool count drops from
  25 to 22 (config-group rows 20 → 17). Plan mode no longer whitelists the
  background-shell reader (`shell_manage` can also kill/input, so it is not
  read-only; plan mode can't start a background shell to manage anyway).
- **`read_attachment` folded into `read` (one unified reader).** The standalone
  `read_attachment` tool is removed; `read` now auto-detects a rich document
  (PDF, DOCX, XLSX, PPTX, HTML, CSV, JSON, XML) and converts it to Markdown
  in-process via `Rubino::Documents`, framed as untrusted user data, while an
  ordinary text/code file keeps its `cat -n` behaviour. The framing switch is
  driven by the detected file kind (fail-closed magic-bytes classification), and
  a converted document escalates to the full `:shell` secret redaction rather
  than read's weaker `:code` profile — so untrusted document bytes never ride the
  trusted-source path. Built-in tool count drops from 26 to 25. Mirrors Claude
  Code's single unified `Read`.

### Added

- **install.sh gains `INSTALL_DOCS` opt-in.** The installer now offers to install
  `pdf-reader` (for in-process PDF reading in `web_fetch` and `read`),
  mirroring the existing `INSTALL_JS` pattern with env-var override
  (`RUBINO_INSTALL_DOCS`), interactive prompt (default no), and non-fatal failure.
- **`web_fetch` converts documents to Markdown instead of refusing them.** PDF,
  DOCX, XLSX, and PPTX fetched via `web_fetch` are now spilled to disk and
  converted to Markdown in-process via `Rubino::Documents` (the same engine the
  `read` tool uses for documents). Opaque binaries (images, audio, video, archives) are still
  refused. Each format needs an optional gem (`pdf-reader`, `docx`, `roo`,
  `ruby_powerpoint`); when a gem is missing, `web_fetch` returns an actionable
  hint instead of failing silently.
- **`web_fetch` gains a `method` parameter.** `method: "get"` (default) fetches
  the body; `method: "head"` does a SSRF-safe link-check returning status,
  Content-Type, and Content-Length — no body fetch.
- **`rubino setup` offers to install `pdf-reader`.** The interactive setup now
  asks before installing the optional gem for PDF/DOCX/XLSX/PPTX in-process
  conversion.
- **`rubino doctor` names the exact gem for missing document formats.** When a
  document converter's optional gem isn't installed, doctor reports the format
  as unavailable and tells you which gem to install (e.g. "run `gem install roo`
  (or `rubino setup`) to enable").
- **Delete skills without leaving the tool.** The `skill` tool gains
  `action: "delete"`, the in-process counterpart to create/edit/patch/write_file:
  it removes a home-authored skill (dropping its provenance-ledger entry when it
  has one), confined to the home skills dir and refusing bundled skills, and is
  approval-gated like every other skill write. This closes a real trap — skills
  live under `~/.rubino/skills`, which the OS write-jail refuses to let the shell
  touch, so deleting one with `rm` failed with no recourse. `rubino skills remove`
  likewise now deletes any home-authored skill (not just git-installed ones)
  instead of punting to a manual `rm`.
- **Escape hatch for out-of-workspace writes (`disable_sandbox`).** When the OS
  write-jail blocks a legitimate write outside the workspace, the model can
  re-run the shell command with `disable_sandbox: true` to run it outside the
  jail — always behind a fresh, explicit approval that discloses it runs outside
  the jail (model-driven, aligned with Claude Code). It sits below `--yolo` and
  below the hardline floor (`rm -rf /` stays denied) and fails closed headless.
  New config `tools.sandbox.escalation`: `off` (no hatch), **`protect-home`**
  (default — `~/.rubino` trust anchors stay OS-refused even when approved), or
  `full` (Codex-style fully-unconfined-on-approval). The write-jail hint now
  steers the model to the right next move (the `skill` tool for `~/.rubino`,
  `disable_sandbox` for elsewhere).

### Changed

- **`edit` absorbs `multi_edit`.** The `edit` tool now accepts an optional
  `edits` array (each `{old_string, new_string, replace_all?}`) for multiple
  replacements in one file, applied atomically (all-or-nothing) and sequentially
  (later edits see the result of earlier ones) — the former `multi_edit`
  behaviour, folded into a single editing surface (mirrors Claude Code's `Edit`).
  The scalar `old_string`/`new_string` form is unchanged; pass one form or the
  other, not both.

### Removed

- **`multi_edit` tool removed** — folded into `edit` (see Changed above).
- **`apply_patch` tool removed.** Unified-diff application is dropped; `edit`
  and `write` cover its use, and unified diffs are the format small local models
  most often corrupt. Built-in tool count is now 26 (was 28).

### Added

- **`shell_manage` gains a `wait` action.** Blocks until the background process
  exits (or `timeout` elapses — default 180s, max 600s) and returns its final
  output plus exit code in one call, so a long job is awaited without a
  `tail`/`output` poll loop (mirrors Hermes' `process(action="wait")`). `tail`
  keeps its role as a quick progress peek (blocks on new bytes/exit/`timeout`,
  default 30s/max 300s). `wait` is read-only (`:low`, unprompted) alongside
  `output`/`tail`; a positive explicit `timeout` always wins over the action's
  own default. When `wait` already delivered the result, the async
  `[background-shell] … completed` notice is suppressed so the model isn't
  told twice.

### Changed

- **`task` now runs synchronously by default; `background: true` opts in.**
  Every `task` call previously backgrounded unconditionally (see the
  background-by-default entry further below). The model now gets the child's
  result inline by default — matching Claude Code's subagent default — and
  backgrounds a subagent only when it has other useful work to do meanwhile.
  `background: false` is now just the explicit spelling of the default
  synchronous path; both paths share the same nesting caps and ownership
  stamping.

### Fixed

- **Background completion notices land on time under streaming, and stop
  leaking the local path.** `[background-shell]`/`[background-task]` notices
  now deliver at the next tool boundary instead of one iteration late, so a
  shell or subagent that finishes mid-turn no longer goes unseen until after
  a stale answer was already committed. The shell completion notice also
  collapses `$HOME` to `~` in the echoed command so it never leaks the
  operator's absolute local path, and these synthetic notices are excluded
  from the Esc-Esc rewind picker (they're runtime context, not a user-typed
  turn).
- **Custom tools (`~/.rubino/tools/*.rb`) are actually loaded now (#610).**
  `CustomToolLoader#load_all!` had no call site anywhere in the boot path, so
  a user-authored tool file had zero effect no matter how it was written.
  `Registry#register_defaults!` now calls it, right before the `Rubino::Tool`
  safety-net sweep, so a plain `class Foo < Rubino::Tool` subclass — the same
  DSL every built-in tool uses — registers correctly (it's collected by the
  `inherited` hook when the file loads, then picked up by that same sweep).
  The older `Rubino.define_tool do...end` block DSL still works too, and
  — unlike the class form — can deliberately shadow a same-named built-in,
  since it registers unconditionally the moment its file loads.
- **The exit-time `--resume` hint always prints the short id, not the session
  title.** `print_resume_hint` used to prefer the human-readable title (free
  text — sometimes a whole sentence, with spaces that break shell copy-paste
  and no uniqueness guarantee) over the session id. It now always shows the
  same short 8-char id `print_auto_resume_line` and `find_by_id_or_title`'s
  prefix match already agree on.
- **A second paste immediately after a collapsed one no longer vanishes into
  the first placeholder.** Two consecutive large pastes used to coalesce into
  the SAME `[Pasted text #N]` chip, silently growing its line count with no
  visible change — the second paste looked like it did nothing. Each paste is
  handled independently again: a small one inlines as plain text, a large one
  gets its own distinct placeholder.
- **Custom slash commands now expand in one-shot mode.** `rubino chat -q
  "/mycommand args"` (and `rubino prompt "/mycommand args"`) used to send that
  literal, unrendered string straight to the model — `.rubino/commands/*.md`
  templates only ever expanded inside the interactive `rubino chat` REPL.
  One-shot now checks the query against the same `Commands::Loader` the REPL
  uses and, on a match, sends the rendered template (`$ARGUMENTS`/`$1..$9`,
  `@file` refs, the opt-in `!`-shell injection, and `agent:` frontmatter
  routing) as the turn's content instead. Scoped to custom commands only —
  built-ins (`/model`, `/new`, `/compact`, …), agent-pin switching, skill
  invocation, and `--preview` remain interactive-only, so an unrecognized
  `/name` (or ordinary text that merely starts with `/`) still passes through
  unchanged.

## [0.5.2.2] - 2026-07-01

### Added

- **Background shells get the same dev UX as background subagents.** A shell
  started with `run_in_background: true` now appears in the `↓` picker and the
  live cards alongside subagents, can be FOCUSED (Enter attaches to a cleared
  view that live-tails its output and lets you type straight to its stdin), and
  STOPPED with `/stop`. Interactive shells run on a real PTY, so `y/N` prompts,
  sudo passwords, and tty-aware programs work where a plain pipe couldn't.
  `probe` (an instant output snapshot — no LLM call), `steer` (→ stdin), the
  `/agents` list and the `/status` count all treat shells consistently with
  subagents. Stopping a subagent **cascade-kills the background shells it
  opened** (shells the user/main agent opened are left running). Ported from
  Hermes' `ptyprocess`/`process_registry` model.
- **H1/H2 headings get breathing room** — a blank line above and below big
  headings so they break the surrounding prose instead of sitting glued to it;
  H3+ stay compact.

### Changed

- **The per-turn wall clock is disabled by default.** `agent.max_turn_seconds`
  (was 600s) guillotined legitimate multi-file work on slow local models — a real
  docs-vs-code audit runs dozens of tool calls over 10+ minutes and was
  force-summarized into a confused non-answer. The default is now `nil`
  (disabled); the tool-iteration budget (`max_tool_iterations`, 90) is the
  runaway guard, and per-tool timeouts bound a hung tool. Hermes parity (its
  IterationBudget has no clock). Set a positive number to re-arm the clock as a
  backstop.
- The background picker header reads "background" (not "subagents") now that it
  lists background shells alongside subagents.

### Fixed

- **Truncated subagents are reported as PARTIAL, not "completed".** A background
  subagent force-summarized at its budget/time cap used to return its partial
  progress recap as a normal completion, so the parent — and you — got a false
  success with no real deliverable. The turn's terminal stop reason now flows out
  of the loop, and the completion notice, the main-timeline marker, and
  `task_result` all mark a cut-off child **PARTIAL** with a banner telling the
  parent the delegated work is unfinished — so it recovers (re-delegates or
  finishes the work itself) instead of trusting a false completion.
- **A subagent's own `max_turns` budget is honored again.** `explore`'s per-agent
  cap (20) was silently dropped — the runner passed `nil` for subagents, so the
  cap never applied. A subagent now honors its cap and, on reaching it, surfaces
  the budget-extension request (#574) instead of silently force-summarizing.
- **`rubino update` now reports the new version correctly.** After `gem update`
  pulled a newer gem, the command read the version via
  `Gem::Specification.find_by_name`, which returns the spec ACTIVATED in the
  running process — so it still saw the old version and wrongly printed "rubino is
  already up to date" even though the update had installed. It now `Gem.refresh`es
  and reads the HIGHEST installed version (`find_all_by_name(...).max`), so the
  post-update message reflects what was actually installed.

## [0.5.2.1] - 2026-06-26

### Fixed

- **Symlinked workspace roots broke three path checks.** Several modules compared
  a symlink-resolved path against a NON-resolved root, so a workspace reached
  through a symlink (macOS `/etc` → `/private/etc`, `/var` → `/private/var`, or
  any symlinked checkout) defeated the match:
  - **SecretPath** — `secret?("/etc/sudoers")` returned `false` and the
    `~/.ssh`/`~/.aws`/… credential read-gate classified nothing, silently
    no-op'ing the write-approval gate and read-block for those paths.
  - **IgnoreRules** — `git rev-parse --show-toplevel` returns the realpath, so
    the allowed-set rebase dropped *every* file and the whole tree read as
    git-ignored; `grep`/`glob` then returned nothing under a symlinked checkout.
  - **Skills::Registry** — an untrusted repo's project-local `.rubino/skills` was
    not recognised as project-local, so the trust gate failed to drop it (hostile
    project skills could load in an untrusted directory).

  All three now resolve both sides of the comparison through `realpath` /
  `canonical_path`. Defense-in-depth — not security boundaries.
- **`grep` Ruby fallback now matches dotfiles.** Without ripgrep on PATH, the
  fallback globbed `**/<include>` without `FNM_DOTMATCH`, so an include like
  `*.env` never matched `.env`/`.envrc` — exactly the secret-bearing files. The
  include glob now matches dotfiles, mirroring `rg --glob`.

## [0.5.2] - 2026-06-26

### Added

- **Live formatted-markdown streaming.** The in-flight model stream now renders
  as formatted markdown while it arrives (Stage 1), painted as atomic frames via
  DEC-2026 synchronized output so a fast stream never tears mid-update (Stage 2),
  with committed code blocks syntax-highlighted through Rouge (Stage 3). (#592,
  #593, #594)
- **Leaked tool-call recovery.** Models that emit a tool call as plain text or
  garbled XML/JSON markup instead of a structured call (MiniMax-M3 and other
  tool-loop models) now have those calls re-parsed into real `tool_calls` at the
  transport layer so they actually execute, including a garbled `<invoke">`
  variant.
- **`write` content preview.** The `write` tool box now shows a preview of the
  content being written.

### Changed

- Raise the default `max_tool_iterations` from 25 to 90 (Hermes-aligned), so long
  tool-driven turns no longer hit the ceiling mid-task.
- Teach the agent (via the build prompt) to read the compressed tool-output
  markers introduced in 0.5.1.

### Fixed

- Render any unterminated code fence as a code box, matching CommonMark's
  end-of-file fence auto-close, instead of leaking the raw backticks. (#595)
- Merge consecutive same-role messages on the Anthropic-family wire so the
  request shape stays valid. (#597)
- Give MiniMax its full output ceiling so a long thinking block no longer starves
  the visible output (a root cause of heavy-turn "invalid params" death).
- Keep a 5xx-wrapped "invalid params" response on the retryable path.
- Multi-line `ask()` prompts no longer erase terminal scrollback.
- Exclude synthetic `[harness control]` injections from the rewind picker.
- Fix an installed-gem launch crash (`uninitialized constant Rubino::TAGLINE`).

### Removed

- Drop the dead `server.*` config section, the orphaned `ask_parent` takeover and
  ask/reply substrate, and dead code surfaced by the post-removal audit.

### Docs

- Mark native OAuth as not wired end-to-end (WIP).

## [0.5.1] - 2026-06-25

### Added

- **Tool-output compression (deterministic, off by default).** A no-LLM content
  router at the single `Agent::ToolExecutor` seam compresses high-volume tool
  output before it reaches the model: test/build/lint logs are reduced to their
  failures + summary (≈97% fewer tokens on a failing suite, every failure kept),
  and a whole-file source read can be returned as a skeleton (signatures kept,
  large bodies elided behind a `read offset:/limit:` pointer). Diffs, grep/search
  results, JSON, and short output pass through **byte-identical**. Reversibility
  reuses the existing spill: the full original is written to
  `tool-results/<call_id>.txt` and the compressed output points the model there —
  no separate store/tool. When enabled, `read` and `shell` expose a `compress`
  parameter (default true) so the model can opt a single call out and get the
  verbatim output. Master switch `tool_output_compression.enabled` (default
  `false`); `rubino setup` offers to turn it on. See
  [configuration.md](docs/configuration.md#tool_output_compression).
- **Multi-language code compression.** The whole-file source-skeleton compressor
  now covers more than Ruby. `tool_output_compression.code.languages` (default
  `["ruby"]`) selects which languages get skeletonised: Ruby (built-in Prism
  parser), Python (stdlib `ast` via your `python3` — a no-op if `python3` isn't
  on PATH), and JavaScript / TypeScript / TSX (via the optional
  `tree_sitter_language_pack` gem — a no-op until it's installed). A read in an
  unlisted language passes through verbatim. `rubino setup` adds a language
  picker and, if you choose JS/TS, offers to install the parser gem.
- **Agent-attach view.** At the idle prompt, `↓` opens the subagent picker and
  `Enter` now **attaches** to the highlighted background subagent: the screen
  switches to that agent's OWN full timeline (its tool calls and what it said,
  replayed from its session) and the input prompt becomes scoped — `sa_xxxx ❯`.
  While attached, typed text steers the running child (or answers it when it's
  blocked on you); `←` on the empty prompt (or the picker's `◂ main` row) returns
  to the main timeline, and the picker doubles as a switcher between agents. This
  replaces the bounded registry snapshot the picker's Enter used to show with the
  agent's real conversation, and makes the global `/agents <id> steer/probe` and
  `/reply <id>` forms redundant while attached. The attached view **live-tails**
  the child's stream (tool rows and streaming prose) exactly like the main agent
  instead of freezing on a snapshot, and `/back` / `/detach` return to the main
  agent regardless of composer-draft state (#82, #85, #87).
- **`api.allow_public_bind` gate.** Because the API server can execute shell
  tools, binding it to a non-loopback address (`--host 0.0.0.0`,
  `RUBINO_API_HOST`) now **refuses to boot** unless `api.allow_public_bind: true`
  is set in `config.yml`; when opted in, the server prints a one-time exposure
  warning. Loopback binds are unaffected (#577).
- **MCP tool transparency + parallel startup.** An MCP tool's display label now
  carries its source — the live tool card and the approval card both show
  `<bare> (mcp:<server>)`, so you can tell at a glance that an out-of-process
  server is running (the model-facing tool name is unchanged) (#582). MCP
  servers also now connect **in parallel** at boot, so one hanging server no
  longer serializes startup (#576).
- **Read-only meta-commands run immediately while a turn is active.** A small
  set of non-mutating slash commands (`/agents`, `/tasks`, `/stop`, `/status`,
  `/jobs`, `/help`, `/commands`, `/dirs`) now execute **immediately** mid-turn
  instead of queuing — so you can drill into a sub-agent, stop the run, or check
  status without interrupting. State-mutating commands (`/model`, `/clear`,
  `/new`, `/config`, `/mode`, …) show a transient `⚠ <cmd> is not available
  during an active turn — press Esc to interrupt first` notice; plain text still
  queues, and `Esc` interrupts.
- **Interactive CLI session picker.** A bare `rubino sessions` on a TTY opens an
  interactive picker (id, title, message count, dir, age; arrow-key highlight,
  type-to-filter, `Esc` cancels) and `Enter` resumes the chosen session. On a
  pipe / non-TTY it prints a script-safe list; `sessions list` stays list-only.
  The picker is cwd-scoped by default; `--all` unscopes it.
- **`/sessions rename <id|title> <new title>`.** Rename a session from the REPL
  (#45).
- **Aux-LLM session titles.** When `auxiliary.title` names a concrete backend,
  new sessions get an LLM-generated, length-capped summary title; the
  deterministic derivation stays the default and the fallback (#45).
- **Streaming GFM table rendering (#89).** A markdown table now renders as a
  live, correctly-fitted table as it streams — a sliding window of recent rows
  grows in place — instead of leaking raw `| col | col |` pipes that only snap
  into a table once the message completes.

### Changed

- **Provider auto-routing.** With `model.provider: "auto"` (the default), the
  concrete provider is derived from the model id (`openai/*` → OpenAI); the
  setup wizard / auto-detect write an explicit provider when a non-OpenAI
  backend is chosen.
- **Credential check uses provider-specific env vars.** The credential check
  and key resolution now read the env var for the configured provider
  (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `BEDROCK_API_KEY`,
  `MINIMAX_API_KEY`, and `<PROVIDER>_API_KEY` for anything else, e.g.
  `DEEPSEEK_API_KEY`). A non-OpenAI provider no longer silently falls back to
  `OPENAI_API_KEY` (only providers explicitly marked `openai_compatible` /
  `anthropic_compatible` fall back to `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`).
- **`security.confirm_policy` default is `dangerous_only`.** Safe shell commands
  run unprompted; only commands matching a dangerous pattern prompt. Set
  `confirm_policy: confirm_all` to restore prompt-on-everything. The
  non-bypassable hardline floor and `permissions: deny` always run first
  regardless of policy.
- **Removed the built-in `run_tests` and `github` tools.** Running tests and
  GitHub/git operations now go through the generic `shell` tool (with its
  hardened git arg parsing), matching the field norm and shrinking the tool
  surface.
- **Blocked-tool results are now typed errors.** When a tool call is blocked
  (denied by approval, sandbox, or policy), its result is returned to the model
  as a typed error with explicit anti-confabulation wording, so the model is told
  the action did NOT happen instead of being free to assume success (#583).
- **Single status bar during a turn.** The animated facet activity row is folded
  into the model/ctx footer (one bar, not two); the "esc to interrupt" hint shows
  exactly once, and a mid-stream **waiting indicator** resurfaces beneath the
  in-flight tail after a short window of model/transport silence and drops away
  the instant tokens resume (#21, #56b — `/status` now also shows the workspace
  cwd line).
- **FIFO approval queue for concurrent subagents.** When multiple subagents need
  approval at once, one modal shows at a time with an "(N more queued)"
  indicator that dequeues on resolve, and async-completion notices no longer
  print over an active modal. Subagent approvals also **escalate to the parent's
  approval card at any nesting depth**, so a nested child no longer fail-closes
  with a noninteractive block (#86).
- **Slash commands dispatch while attached to a subagent** (`/stop <id>`,
  `/agents`, `/status`, …) instead of being steered into the child as text;
  `/skills list` / `/skills ls` show the skills list rather than trying to
  activate a skill named `list`; `/think off` hides the reasoning aside for
  always-thinking models unless an explicit `/reasoning` is set; `/config <key>`
  resolves the short labels `/status` advertises (`reasoning`, `effort`,
  `think`) (#62, #66, #87).
- **`/new` returns instantly.** The end-of-session memory flush is enqueued as a
  background job instead of running a synchronous aux-LLM extract, so starting a
  new session no longer freezes the prompt for 2–3s.
- **Headless one-shot drains only its own jobs.** `rubino -q` now emits and
  flushes the JSON result envelope before draining, and scopes the post-turn job
  drain to the run's own session, so a one-shot returns immediately even with a
  background job backlog.
- **Subagent cards are distinguishable + carry the task id.** Concurrent
  subagent cards label by a dimension drawn from the task prompt (rather than the
  bare agent type), background "done" markers carry the task id, and the live
  elapsed counter shows seconds (`1m05s`) so it visibly advances (#44, #570).
- **Pastes coalesce into a single placeholder**, input history is recalled and
  persisted, `Enter` accepts the highlighted dropdown candidate, and
  `task_result` running-polls no longer flood the transcript (#524, #525).
- **System-prompt grounding for control + tools.** The cap / continuation /
  summary control is framed as trusted `[harness control]` so MiniMax-M3 stops
  treating it as prompt-injection (#75); the background-shell lifecycle is primed
  so the model uses `shell_output` / `shell_kill` correctly; the verification
  step is scoped to never modify the environment and to stop honestly.
- **Memory-flush best-effort boundary** made airtight (#471), so a failure
  flushing memory at shutdown can't take down the run.

### Removed

- **Child→parent `ask_parent` / `answer_child` tools.** Subagents are
  non-blocking background workers and can no longer pause mid-task to ask their
  parent (or the human) a question; instead they make sensible default calls and
  surface open decisions in their result. The two model-facing tools that
  implemented that channel — `ask_parent` (the child→parent escalation) and
  `answer_child` (the parent's reply) — are gone. The parent→child `steer` /
  `probe` tools and the human approval gate (`/reply` for a child parked on an
  approval) are unchanged. `tasks.ask_parent_timeout` is now vestigial.
- **`streaming.cursor` config key.** It was dead config (assigned, never read)
  and is no longer accepted — remove it from any `config.yml`.
- **`security.require_confirmation_for_shell` config key.** Replaced by
  `security.confirm_policy` (`dangerous_only` | `confirm_all`); the old key is no
  longer honored.

### Security

- **Hermes-style secret handling (#506).** Adopts the Hermes secret model across
  the agent: the structured `read` tool blocks `.env` and credential files
  outright, and secret **values** are redacted in the output of `read`, `grep`,
  `shell` (including the live stream seam, not just the final buffer, #507),
  `summarize`, and `read_attachment` (#511/#512). A `security.redact_secrets`
  toggle (default **on**) controls redaction. The earlier per-read secret-file
  approval gate was removed in favour of this block-list + redaction model
  (#480). Over-broad redaction was then narrowed: the `ENV_ASSIGN` pattern is
  anchored so `AUTHORS` / `SECRETARY` pass through while `API_KEY` / `AUTH_TOKEN`
  still redact, the Telegram-token pattern is pinned to its canonical shape, and
  fully-masked secrets carry an explicit marker rather than a bare `***`
  (#67, #516).
- **Secrets are no longer persisted to memory (#99).** A `Security::SecretDetector`
  is wired into the memory write path (it refuses an explicit save and the
  auto-extract persist path) and into the redactor, catching prefixed key
  shapes, prefix-less AWS secret keys, and a high-entropy heuristic — previously
  an `sk-proj-…` key could be saved verbatim and re-injected into every future
  system prompt.
- **Removed the dedicated `git` tool (RCE bypass).** Git now runs through the
  hardened `shell` with strict arg parsing that rejects exec vectors
  (`--ext-diff`, `-c`, textconv, …) plus a `GIT_HARDENED_ENV`, instead of a tool
  that could be steered into arbitrary command execution (#536/#553).
- **Dangerous write/exec flag-forms prompt under the default gate (#61).**
  `git -c` / `--output`, `sed -i`, `sort -o`, `find -delete` / `-exec`,
  `tar --to-command`, `tee`, interpreter `-c` / `-e` / `--eval`, etc. no longer
  auto-run under `dangerous_only`, while bare interpreters and read-only forms
  still auto-run. A shared `Security::CommandNormalizer` also closes
  line-continuation evasion (e.g. `rm -r\<newline>f` no longer slips past the
  danger/approval layer).
- **Extended HOME credential read-block.** Reading credential stores under HOME
  is blocked and a base64-decode-pipe-to-shell (`echo … | base64 -d | sh`) is
  flagged dangerous (#519); the denylist now covers `.ssh`, `.aws`, `.netrc`,
  `.git-credentials`, `.kube`, `.docker`, `.gnupg`, `.azure`, and `.config/gh`
  (#537). A write through a **dangling in-workspace symlink** can no longer
  escape the sandbox — the link target is resolved before the create-new-file
  fallback (#62).
- **Tighten the `ruby_llm` floor to `>= 1.16` (#508).** The adapter wires native
  providers through ruby_llm's generic `<provider>_api_base=` setters
  (deepseek/mistral/etc., #482), which only exist from ruby_llm 1.16.0. The
  gemspec previously allowed `~> 1.0`, so a fresh `gem install` could resolve
  ruby_llm 1.15 and crash at runtime with `NoMethodError`. The dependency is now
  `>= 1.16, < 2.0`.
- **Secret masking on `config set`.** `rubino config set` now masks the echoed
  value when the key looks secret (`api_key`, `token`, `password`, `secret`,
  `authorization`, …) and when the value itself contains inline credentials
  (`key=value`, `Bearer …`, URL userinfo, `curl -u`, `mysql -p…`), so keys are
  not printed in the clear to the terminal/scrollback.
- **Sanitized untrusted text rendered to the terminal (CWE-150).** Text that
  originates from the model, tools, or filenames (subagent cards, `/`-palette and
  `@`-picker menu labels, and the remaining CLI aside sinks — probe, reasoning,
  open-fence, branch title) is now defanged of ANSI/OSC escape sequences before
  it is written, closing an escape-injection class (#563/#564/#565–#568).
- **Vision egress hardening.** The `vision` tool now honours
  `attachments.policy.aux_vision_egress` (default `true`): set it to `false` and
  the tool refuses to send an image to an external auxiliary model, returning a
  clean error instead of egressing the bytes (#578). Before any egress it also
  **content-sniffs** the file (magic bytes win over the extension, fail-closed),
  so a mislabelled or non-image file can't be smuggled to the external host
  (#579).
- **OS sandbox covers more executors.** The OS write-jail (Landlock / Seatbelt)
  now also confines background shells, `ruby`, and `run_tests`, with relaxation
  gated on verified enforcement; a write-jail `EACCES` outside the workspace
  produces an attributable "blocked by write-jail" hint (#74).

### Fixed

- **MiniMax-M3 pre-tool-call "freeze".** Thinking/reasoning now defaults ON for
  every provider (it was deliberately off for MiniMax-family ids). On the
  anthropic-compatible path rubino now sends `thinking: {type: enabled,
  budget_tokens: …}` and streams the model's reasoning deltas — so the multi-
  second window where M3 reasons toward a tool-call is filled with visible
  streamed reasoning instead of dead air (the symptom that read as the agent
  "freezing" when it spawned subagents). Matches the reference agent's default
  `reasoning_effort: medium`. A backend that rejects the budget is caught and
  retried once without it (#75), so default-on is safe; set
  `providers.<name>.supports_thinking: false` to opt out.
- **MCP `degraded` server state.** `/mcp` and `rubino doctor` now distinguish a
  reachable server (`●`) from a **degraded** one (`⚠` — the process is alive but
  a protocol call such as `tools/list` failed), instead of reporting it as plain
  reachable (#575).
- **Session-title length cap.** A renamed session title is now length-capped at
  rename and truncated on render, so an over-long title can't disrupt status /
  session-list layout (#581).
- **Streaming fidelity.** A streaming turn no longer re-executes or re-surfaces
  tool calls it already ran (no double "started" line or duplicate final tool)
  (#53), and a split think/fence sentinel is held across the message-boundary
  flush so reasoning no longer leaks into the body and prose isn't torn apart
  (#43/#54). A committed markdown table glued to trailing prose no longer leaks
  raw pipes, and a too-wide table fits the pane instead of tearing the border.
- **Subagent / multiplexer UI.** A running `blocked_on_parent` sub stays visible
  in the footer while listed; cap-rejected delegation renders a neutral
  "at capacity" row instead of a phantom failed card; the close-row / replay use
  the per-call subagent name instead of a shared stale one (#35); the agent
  picker opens reliably on `↓` and `←`/`↑` backs out; picking `◂ main` returns to
  main immediately mid-turn; a nested child's menu no longer crashes it; and the
  parent autonomously resumes at idle when background subagents finish while
  detached (#37, #44, #51, #561).
- **Interrupt handling.** `Esc` at the tool-dispatch boundary raises a clean
  interrupt instead of a malformed continuation that the backend rejects as
  "invalid params"; a stray `Ctrl-C` exits cleanly (130) with no raw `net/http`
  backtrace; and a background thread never dumps a backtrace on death.
- **Input papercuts.** Backspace (`DEL 0x7f`) deletes instead of inserting a
  space (#522); a single `Ctrl-D` at an idle empty composer no longer hangs, and
  fast input bursts coalesce their redraws (#520). Several composer
  render/input races and resize-while-typing reflows that duplicated the
  in-progress input into the scrollback are fixed, including chained resizes and
  the resize REPAINT path (#481/#485/#486/#499/#500/#501/#503).
- **`edit` no longer crashes on non-UTF-8 / binary buffers.** Fuzzy-match
  normalization passes invalid-encoding bytes through verbatim (#47), atomic
  writes are binmode'd so binary buffers never transcode (the intermittent
  in-session edit crash on accented files) (#65), and `clean_slice` reinterprets
  binary as UTF-8 rather than calling `.encode` (#58). A failed edit / read /
  write now shows `✗` instead of a green `✓`.
- **Background jobs and shells.** The job queue drains reliably — stale `running`
  rows are reclaimed after the lease expires (#76) and `ExtractMemoryJob` is
  prioritized over `SummarizeSessionJob` so save→recall doesn't lag (#79);
  finished background shells are retired with their buffer and exit status
  retained, so `shell_output` / `shell_tail` / `shell_kill` stay reachable next
  turn (#78); shell cancel no longer orphans the child process group, and a
  finished background shell auto-wakes the model.
- **Turn-ledger honesty.** Blocked / errored tools no longer count toward the
  "N tools ran / M edits" ledger, so a turn whose only tool was refused stops
  telling you to review nonexistent changes; the force-summary and closing-summary
  nudges are grounded in the truthful turn ledger so the model can't confabulate
  having done nothing (#36/#84). MiniMax HTTP 429 / quota errors are categorized
  as retryable rate-limit (honouring `Retry-After`) instead of "Invalid request",
  and the anti-confabulation note no longer over-fires on accurate local caveats.
- **Sessions / resume / doctor.** A per-session `flock` guard stops a concurrent
  `--continue` from forking a moving transcript (#543), replay renders only the
  new tail of a restated final message (#542), `--resume <id>` is validated
  before the boot banner (#521), and `doctor` warns instead of false-green when
  no usable credential exists and no longer implies an unverified key is
  validated (#541/#546).
- **Non-native provider wiring (#482).** Fixed the preflight that falsely
  reported non-native providers (deepseek/mistral/…) as ready; they are now
  wired through the generic `<provider>_api_base=` setters and the run stops
  on an unreachable endpoint instead of failing later. Transient name-resolution
  failures (`EAI_AGAIN`) are retried rather than fatal, and a stream that ends
  without a finish signal is recovered instead of failing the turn.
- **Parent-death reaps child shells (#478).** When the agent process dies, the
  long-running child shells it spawned are reaped instead of being orphaned,
  using a trap-safe SIGTERM/SIGHUP handler (no `Mutex` inside the signal trap).
- **Compaction no-op loop (#484).** Stopped a busy-loop on an over-budget
  session that has too few messages to compact. The `doom_loop.threshold`
  default is also no longer rejected by its own validator (#60).
- **Memory polish indicator no longer flashes every turn (#59).** The polish
  worker starts only when a row was actually enqueued, the indicator composes
  alongside the ctx bar instead of replacing it, and a verbatim repeat
  short-circuits to the existing row at the write seam.
- **`/exit` and exit codes.** `/exit` routes through the quit-guard, and an
  interactive session exits non-zero on an auth/credential error (#154).
- **CLI DX papercuts.** Fixed the bare-`rubino "prompt"` one-shot path, help-
  session clutter, a bare-prompt did-you-mean edge case, and a `read_attachment`
  hint that suggested markitdown for raster images instead of OCR.
- **Input hardening.** Fixed a raw SQLite3 exception on session input with
  hostile/NUL bytes (#498) and cleaned up `Errno` error messages on the failure
  paths; tightened mcp args validation and assorted low-severity
  config/sessions/resume/CLI papercuts.

## [0.5.0] - 2026-06-15

### Added

- **One-shot tool-activity trace.** The non-interactive text path (`rubino
  prompt` / `-q` / piped `chat`) now prints a concise per-tool activity trace
  by default — one line per tool completion (`· edit foo.rb`, `· bash npm
  test`) — routed to STDERR so the final answer on STDOUT stays clean
  (`x=$(rubino prompt …)` captures only the answer). `--quiet`/`-Q` silences
  the trace (machine-silent path); `--verbose`/`-v` widens each line's args.
  `--output-format json`/`stream-json` (structured events on stdout) and the
  interactive TUI tool-cards are unchanged. Mirrors the Codex/gemini-cli/Hermes
  stderr-trace norm (Hermes `-q` default / `-Q` quiet).

- **Prompt-cache breakpoints (`cache_control`).** The conversation now inserts
  cache breakpoints so the stable prefix (system + tool schemas + prior turns)
  is reused across round-trips, cutting input-token cost/latency.
- **Situational tool-schema gating.** Tool definitions sent to the model are
  scoped to the situation instead of always shipping the full set, reducing
  prompt size and accidental tool selection.
- **Primary-agent switching.** Switch the active primary agent inline with
  `/<name>`, the `/agent` command, or `Tab`; `@` remains reserved for file
  references.
- **Detached post-turn polishing.** A post-turn polishing pass runs detached and
  is cancellable with `Esc`, so it never blocks the next prompt.
- **Stdin pipe for one-shot.** Piped stdin is consumed as the prompt for
  one-shot runs (`echo … | rubino prompt`), enabling unix-style composition.
- **Per-round-trip loop accounting.** Round-trips are counted, usage is summed
  across them, and `tool_calls` are persisted on the streaming path.
- **Machine-readable headless output (`--output-format json | stream-json`, #312).**
  `rubino prompt` / `chat -q` can now emit Claude-Code-aligned JSON for
  CI/automation instead of prose. `--output-format json` (or the `--json` alias)
  prints a single `{type:"result", subtype, is_error, result, session_id,
  exit_reason, num_turns, duration_ms, usage:{input/output/cache_* tokens},
  total_cost_usd, model}` object on stdout at completion; `--output-format
  stream-json` emits JSONL (a `system`/`init` line, then Messages-API-shaped
  `assistant`/`user` step objects, then the same final `result`). In both modes
  ALL JSON goes to stdout and ALL logs/diagnostics/errors to stderr, and markdown
  rendering is suppressed. The fail-closed / exit-code contract is preserved: a
  blocked tool still emits the result with `is_error:true` and a non-zero exit.
  The schema lives in a single shared serializer (`Rubino::Output::ResultSerializer`)
  so it never drifts. `text` (default) is unchanged.
- **Higher tool-loop budget with an interactive extension prompt (#399).** The
  `max_tool_iterations` default is raised from 8 to 25 so longer agent runs no
  longer hit the cap mid-task. When the cap is reached interactively, the run
  pauses with a budget-extension prompt — **Continue +N** (grant another batch),
  **Summarize** (wrap up with what's done), or **Abort** — instead of failing
  silently; headless runs keep the force-summarize behavior.
- **TUI: Ctrl-L clear-screen and a resize-while-typing fix (#395 / #401).**
  `Ctrl-L` now clears the screen from the composer. Fixed a bug where resizing
  the terminal while typing reflowed and duplicated the in-progress input into
  the scrollback.

### Security

- **Hardened/narrowed the command-allowlist convenience layer (SEC-R2-1/2/3).**
  Closes three default-config / bare-`git` paths that could run arbitrary code
  or write arbitrary files past the headless gate **without `--yolo`**:
  - removed code-loading test/build runners (`bundle exec rspec`, …) from the
    **shipped default** `command_allowlist` — they load and execute arbitrary
    project code by design (`rspec -r FILE`), so they are not safely
    auto-approvable (SEC-R2-3);
  - an allowlisted **git** head is now vetted for GLOBAL flags before the
    subcommand (`git -c alias.x='!cmd' x`, `-c core.sshCommand=…`, `-C dir`,
    `--exec-path`) and for code-loading/mutating subcommands (`apply`, `am`,
    `push`, hooks, …); the "approve git always" path now persists only a
    narrowed `git <read-only verb>`, never bare `git` (SEC-R2-1);
  - any allowlisted head whose argument is itself a program
    (`awk`/`sed`/`perl`/`python`/`ruby`/`node`/`tar`/`tee`/`xargs`/shells) is
    default-denied auto-approval, and write flags on read heads (`sort -o`, …)
    are rejected (SEC-R2-2).

  An allowlist is a convenience layer, **not** a security boundary (per industry
  practice the OS sandbox is the real floor, tracked separately); this narrows
  it to close the above default-config and bare-`git` RCEs.

### Hardening

Four adversarial QA rounds fixed ~45 issues across the agent. Highlights:

- **Security.** Hardline-floor canonicalization; OOXML zip-bomb total-archive
  cap; CWE-150 argument sanitization; threat-scanner; tightened
  command-allowlist (see above).
- **Correctness.** UTF-8-safe edits; atomic compaction with auto-switch-to-child;
  resume keeps the full tool history; cwd-scoped sessions; corrupt-DB recovery
  (incl. `NotADatabaseException`); job-queue compare-and-swap; headless job drain
  so memory works in automation.
- **Interrupt.** True cancel — stream cancellation with the partial persisted;
  clean one-shot `SIGINT`/`SIGTERM` labels.
- **Performance.** Bounded huge-output memory; spill/paste eviction; streaming
  grep with consistent ignore rules.
- **UX.** Config validation; `doctor` checks; resilient timeouts and error
  classification.

Every fix was container-verified (non-root QA image, real MiniMax for live
behavior, true 0 failures); a full pre-release functionality sweep confirmed all
subsystems release-ready.

## [0.4.1] - 2026-06-13

### Security

- **Headless approvals now fail closed (#260).** A one-shot / scripted run
  (`rubino prompt`, `chat -q`, no TTY) no longer auto-runs a tool that would
  otherwise prompt: a write/edit, or a shell command not covered by your
  `permissions` / command allowlist / read-only auto-allow, is **blocked, not
  run**. A `blocked: <tool> needs approval …` line goes to stderr and the run
  exits **2**, so CI/automation fails loudly instead of silently skipping (or
  auto-executing). Full auto-exec now requires an explicit **`--yolo`** —
  honored ONLY as a CLI flag, never grantable by a project-local/persisted
  config — and **`--no-yolo`** forces fail-closed even over a yolo boot default.

### Fixed — installer

- **`mise` method (#256)** alongside Homebrew and `rv`, with `global`/`local`
  scope (`RUBINO_INSTALL_SCOPE`); `RUBINO_INSTALL_METHOD` now accepts `mise`.
- **Activation/PATH is persisted to your shell rc (#268)** (`.zshrc` /
  `.bashrc` / `.profile`) and a **post-install fresh-shell gate** fails loudly
  if `rubino` isn't on PATH in a new shell. `RUBINO_NO_MODIFY_RC=1` opts out.
- **`mise` installs pin the latest published gem version (#258/#268)** instead
  of drifting to a pre-release / age-gated build.
- **Method-aware prereq preflight (#272)** (xz/git/toolchain) with real gem
  error surfacing, and a **Debian-12 / glibc-too-old steer from rv → mise
  (#241/#242/#272)** so users don't land on a broken musl Ruby.

### Fixed

- **Config corruption + `doctor` crash on a scalar written over a section (#259).**
- **Streaming persistence (#266):** pre-tool narration is persisted and the
  `tool_calls` audit is populated.
- **TUI render (#269):** table columns sized to content, nested/markdown fences
  consumed, interrupt "ghost" line cleared.
- **Memory extraction bounded by a per-session cursor (#249)** — no more
  re-scanning the whole transcript every turn.
- **Boots under a bare C/POSIX locale (#273)** without
  `Encoding::CompatibilityError`.
- **Session summary folded into the single system message (#253/#254).**

## [0.4.0] - 2026-06-13

### Added — skills from git (#4)

- **`rubino skills install <owner/repo | git-URL>`** — install skills from any
  git repo shipping the `<name>/SKILL.md` layout (`--skill NAME` / `--all` /
  `--list`; `--documents` is shorthand for the four `anthropics/skills`
  document skills). Provenance lands in `~/.rubino/skills/.sources.json`, so
  **`rubino skills update`** re-fetches from the recorded source (up-to-date vs
  updated by commit) and **`rubino skills remove NAME`** only deletes what this
  mechanism installed. `rubino skills list` gains a Source column.
- The skill registry now also discovers the agent-neutral `.agents/skills/`
  and `~/.agents/skills/` dirs (the `npx skills` / Gemini CLI convention) —
  additive, lowest precedence, trust-gated like `.rubino/skills`.

### Added

- **`/agents <id>` watch — live tool-output tail (#5).** The drill-in watch grows an `output:` block showing the tail of the running subagent's current tool output, clearing when the tool finishes.
- **`soffice` and `qpdf` in the `[Environment]` probe (#4/#6)** so the agent honestly reports whether LibreOffice/qpdf are available for the document skills.

### Fixed

- **`read_attachment` extension-spoof gate now covers document MIMEs (#239).** A text file named `report.docx` reads inline as text instead of bouncing off the document converter; a real `.docx` (ZIP magic) still classifies as a document.
- **No more CLI crash under a C/POSIX locale (#250).** Skill and context files are read as UTF-8 rather than the ambient (US-ASCII) encoding, so `rubino skills list` and prompt assembly no longer raise `invalid byte sequence` on minimal Linux/Docker images.
- **Installer no longer always exits 1 on a fresh Linux box (#240).** Fixed an unbound `rv_bin` under `set -u` and an invalid `gem environment gembindir` call; `curl … | bash` now installs cleanly and is idempotent.

### Internal

- **Test stability (#236):** PTY capture specs read to the child's EOF instead of treating a 0.5s quiet window as end-of-output, removing a rare 2-failure flake under concurrent suite load.
- **Approval-handoff guard (#10):** the #80 unit guard now genuinely fails on a full revert; the PTY handoff spec is relabeled as a happy-path check.

## [0.3.0] - 2026-06-06

Major capability release: the core conversation loop was ported 1:1 from the reference implementation (formalized LLM boundary, retry/backoff/fallback, degenerate-response recovery), background subagents became the default delegation path, the memory subsystem grew a pluggable backend contract with a tiny-Zep SQLite backend that is now the default, CLI gained image/file input and a scroll-native redesign, and a reference-aligned approval model (hardline floor, dangerous-pattern deny, prefix-derived rules) landed. Consolidated from `feature/subagent-view` (#48) plus #49-#58.

### Added — CLI redesign & in-chat surfaces

A scroll-native `rubino chat` refresh plus several new slash commands and input affordances. All are documented under [docs/commands.md](docs/commands.md) and [docs/configuration.md](docs/configuration.md).

- **Rail input + status bar.** The chat input now leads with a red `▍` rail and a clean `❯` caret; a dim status bar pinned under the input shows the session mode (dim `default` / yellow `plan` / red `yolo`), the resolved model id, and context saturation. Configurable via `display.statusbar` (default on), `display.tool_output_preview_lines`, and `display.input_max_rows`.
- **File-backed paste pipeline.** A multi-line paste collapses to a `[Pasted text #N +M lines]` placeholder that expands on send; a very large paste overflows to `<home>/sessions/<id>/paste_N.txt` with a read-tool pointer. Tuned by `paste.collapse_lines` and `paste.file_threshold_tokens`.
- **`/model`** — show or switch the live session model (persists `model.default`, retargets the running session).
- **Context hygiene** — `/compact` (compact now), `/clear` (alias for `/new`), `/export [path]` (write the transcript as markdown).
- **`Esc Esc` rewind** — at the idle prompt, opens a picker over previous messages and forks the session before the chosen one, pre-filled for editing.
- **Notifications** (`notifications.*`) — attention signals (terminal bell / iTerm2 OSC 9 / optional `command` hook) on a long turn finishing, an approval prompt, or a blocked subagent.
- **Auto-allow read-only shell** (`approvals.auto_allow_readonly`, default on; `approvals.readonly_commands` to extend) — provably read-only commands (`ls`, `grep`, `git log`, …) run without a prompt, below the hardline floor and `permissions: deny`. See [docs/security.md](docs/security.md#auto-allowed-read-only-commands).
- **`!` bang prefix** — run a shell line yourself, no approval gate; output streams into the transcript and is injected so the next turn can act on it.
- **In-chat management surfaces** — `/mcp` (list/restart/disable MCP servers), `/jobs` (the persistent job queue), and `/config` (read/set effective config in the REPL).
- **Type-ahead while working** — Enter interrupts and runs your line next; Alt+Enter (or `/queued`) queues it after the current turn.

### Fixed — approval-model safety (W3: #152 #144 #143 #147 #151)

- **Shift+Tab can no longer blind-cycle into yolo** (#152). The press that
  lands on yolo only ARMS it and shows a confirm toast ("press shift+tab again
  to confirm"); a deliberate second press confirms, a blind mash keeps
  re-arming and never confirms. The toast counts running background subagents
  whose approval gates would drop. An explicit `/mode yolo` stays direct but
  now warns once when live children would start running gated actions
  unprompted.
- **A background-task event can no longer auto-deny an open child approval
  prompt** (#144). The `/agents <id>` `[o]nce/[a]lways/[n]o` prompt treats an
  empty/aborted read as "ask again" (never as an answer); after repeated empty
  reads it leaves the child parked instead of denying. Card repaints are also
  suppressed while an interactive prompt owns the terminal, so a completion
  fold-in can't paint over (or abort) the blocked read. Denying now requires
  an explicit keypress.
- **Policy denials are no longer reported to the model as "denied by user"**
  (#143). `Tools::Result.denied` now threads the deny reason: the hardline
  floor, a `permissions: deny` rule and the doom-loop guard each get their own
  message (all stating "not by the user"), and the doom-loop one nudges the
  model to change strategy instead of retrying. Only a real human rejection
  still reads "Tool execution denied by user."
- **Enter is no longer swallowed by the verb-suggestion dropdown on a complete
  command** (#147). With the menu open, Enter submits when the typed token
  already equals the (sole/selected) candidate — e.g. the exact
  `/agents sa_xxx` the approval hint tells you to run — and when the argument
  slot is empty (`/agents sa_xxx ` with the steer/probe/--stop menu open).
  Arrow-navigating onto a candidate still makes Enter accept it.
- **read-before-edit is now enforced per SESSION, not per turn** (#151). The
  `ReadTracker` is keyed on the session id, so an edit in a later turn no
  longer forces a redundant re-read (and a second approval round-trip) of an
  unchanged file; any on-disk mtime change still demands a fresh read, and a
  resumed session in a new process still starts conservative.

### Added — built-in `ruby-expert` skill

Rubino now ships a built-in **`ruby-expert`** skill so every install makes the
agent a Ruby/Rails expert out of the box — no setup or copy step.

- **New skill source: gem-bundled skills.** The skill registry now always scans
  the gem's own `skills/` directory in addition to the user paths
  (`.rubino/skills`, `~/.rubino/skills`). Built-ins are scanned **first**, so a
  same-named user skill still overrides them. Toggle with the new
  `skills.include_builtin` config key (default `true`).
- **The `ruby-expert` skill** (`skills/ruby-expert/`) is a router `SKILL.md` plus
  twelve bundled references covering: language idioms, metaprogramming, OO design,
  errors & type checking, concurrency, Rails, testing, performance, security,
  tooling, gem authoring, and dates/times/encoding. The agent loads only the
  reference a task needs (3-level progressive disclosure).

### Changed — BREAKING: project renamed `ruby-agent` → Rubino

The project was rebranded from `ruby-agent` to **Rubino**. This is a clean break with **no backward-compatibility fallbacks** — the old names no longer work and must be updated everywhere they are referenced.

- **Gem name:** `ruby_agent` → `rubino-agent` (install with `gem install rubino-agent`). The bare `rubino` name on RubyGems is an unrelated parked gem and is intentionally not used; a thin `lib/rubino-agent.rb` shim lets `require "rubino-agent"` resolve to the canonical `require "rubino"`.
- **CLI command / executable:** `ruby-agent` → `rubino` (e.g. `rubino setup`, `rubino chat`, `rubino server`).
- **Ruby module namespace:** `RubyAgent` → `Rubino` (and `RubyAgent::VERSION` → `Rubino::VERSION`).
- **Config home directory:** `~/.ruby_agent` → `~/.rubino`. No fallback to the old path; move your existing data if you want to keep it.
- **SQLite database filename:** `ruby_agent.sqlite3` → `rubino.sqlite3` (under the resolved home).
- **Environment variables:** every `RUBY_AGENT_*` was renamed to `RUBINO_*`. No fallback reads the old names. Full list:
  - `RUBY_AGENT_HOME` → `RUBINO_HOME`
  - `RUBY_AGENT_ENCRYPTION_KEY` → `RUBINO_ENCRYPTION_KEY`
  - `RUBY_AGENT_API_KEY` → `RUBINO_API_KEY`
  - `RUBY_AGENT_API_HOST` → `RUBINO_API_HOST`
  - `RUBY_AGENT_API_PORT` → `RUBINO_API_PORT`
  - `RUBY_AGENT_TLS` → `RUBINO_TLS`
  - `RUBY_AGENT_WEBHOOK_URL` → `RUBINO_WEBHOOK_URL`
  - `RUBY_AGENT_WEBHOOK_SECRET` → `RUBINO_WEBHOOK_SECRET`
  - `RUBY_AGENT_LOG_LEVEL` → `RUBINO_LOG_LEVEL`
  - `RUBY_AGENT_LOG_FORMAT` → `RUBINO_LOG_FORMAT`
  - `RUBY_AGENT_HYPERLINKS` → `RUBINO_HYPERLINKS`
  - `RUBY_AGENT_ALLOW_FAKE` → `RUBINO_ALLOW_FAKE`
  - `RUBY_AGENT_REAL_HOME` → `RUBINO_REAL_HOME`
  - `RUBY_AGENT_GIT_REF` → `RUBINO_GIT_REF`
  - `RUBY_AGENT_RUBY_VERSION` → `RUBINO_RUBY_VERSION`

The GitHub repository is `github.com/Jhonnyr97/rubino-agent`. Publishing the renamed gem is **not** done as part of this change.

### Fixed

- **Invalid cron schedules can no longer brick the server** (#164): `POST/PATCH /v1/jobs` validates the cron string BEFORE persisting (422 with the canonical validation envelope, nothing committed), and `Jobs::Scheduler` skips + warns on a malformed persisted row instead of crashing boot — existing poisoned DBs recover on restart.
- **Invalid API keys fail fast** (#126): statusless provider auth rejections (e.g. MiniMax "login fail", "incorrect api key") are classified non-retryable AUTH, surfacing the actionable auth error in one round-trip instead of ~60-90s of silent retries.
- **`rubino chat --help` / `rubino prompt --help` print usage** (#134): a help flag on any top-level command is intercepted at dispatch and routed to Thor's help — no provider call, no memory writes.
- **`RUBINO_HOME` relocates skills** (#135): the stock `~/.rubino/skills` entry resolves against the resolved home (same resolver as config/.env/DB/commands), so isolated homes discover their skills.
- **Order-dependent suite abort** (#163): a spec leaking a pared-down tool registry is cleaned up, and the one-shot exit spec converts an unexpected `SystemExit` into a failing example instead of killing the rspec process.

### Documentation

- `docs/api/v1.md` aligned to the real API surface (#165, #166, #167): SSE catalogue documents the non-streaming contract (no `message.delta`/`reasoning.delta`), the approval decision enum lists all seven accepted values with semantics, and `GET /v1/sessions`, `/v1/memory*`, `/v1/tasks*` are documented. A doc-drift spec locks the documented route list to the registered routes.

### Breaking / upgrade notes

- **Default memory backend is now SQLite (tiny-Zep).** `memory.backend` now defaults to `"sqlite"` (previously `"default"`). The new backend reads/writes the `:memory_facts` table; the old `"default"` backend used the `:memories` table. On upgrade, users who were on the previous `"default"` backend and do **not** pin `memory.backend: "default"` in their config will stop reading their prior memory store — the new backend looks only at `:memory_facts`. Your old data in `:memories` is **not deleted**, just no longer read. **No automatic backfill is shipped.** To keep old recall, pin `memory.backend: "default"` in config. (Acceptable for alpha; documented here.)

### Added

#### Subagents & delegation
- Background subagents: the `task` tool is now background-by-default (Claude-Code-modeled), so a parent run delegates without blocking on the child (#50). Subagent delegation via the `task` tool is wired on both CLI and API.
- CLI live nested view of subagent activity (Phase 1).

#### CLI image & file input
- Headless image attachment for one-shot runs (`-q` / prompt) via `--image` and `@image` (#53).
- Interactive image input: `@image`, drag-drop path, and clipboard paste resolve to `image_paths` (#49). New `ImageInput` path; vision is served via the configured aux model.

#### Shell
- `shell_input` tool to answer interactive prompts of background shells over stdin, enabling interactive subprocesses (#52).

#### Memory
- Pluggable `Memory::Backend` contract + registry (mirrors `Tools::Registry`) and a `memory backend` command to select the active backend.
- tiny-Zep SQLite memory backend: LLM fact extraction, temporal tracking, and hybrid (FTS5 + best-effort vector) retrieval, with graph-lite entities/edges and 1-hop expansion.

#### Approvals (reference-aligned, S1-S7)
- Non-bypassable hardline deny floor (S1).
- `DangerousPatterns` with explicit deny-before-allow ordering (S2).
- `PrefixDeriver` + rule-keyed session approval cache (S3); a `:prefix` rule is only derived for the shell tool.
- `security.confirm_policy` (`confirm_all` default | `dangerous_only`) (S4).
- `/v1` enum + enriched approval payload + `always_prefix` persistence (S5).
- CLI scopes persist derived rules (prefix/command); `always_tool` stays CLI-only (S7).

#### Skills
- Directory-based skills with 3-level progressive disclosure and a registered `SkillTool` (A).
- Mandatory skill index injected into the system prompt (B).
- Registry honors `StateRepository` disable on both index and load (C).

#### Core loop port (1:1 from the reference)
- Formalized LLM boundary: normalized `Request` + `Response` (slice 1).
- `ResponseValidator` + empty-response retry (slice 2).
- `BackoffPolicy` + `ErrorClassifier` (unknown -> retryable) (slice 3).
- `ModelCallRunner` inner retry loop (slice 4).
- `DegenerateResponseRecovery` ladder (prefill-to-continue) (slice 5).
- `ReasoningManager` (thinking render + echo-back seam) (slice 6).
- `FallbackChain` (provider/model rotation, restore primary) (slice 7).
- Max-iterations toolless summary (slice 8).
- `TruncationContinuation` + dead-branch cleanup (slice 9).

#### CLI / UX
- Scroll-native visual redesign of `rubino chat` (M0 + M2).
- Bottom-pinned composer (visible input while the agent streams above); steering — type/inject messages mid-turn (queued for next loop boundary).
- Inline completion dropdown with arrow-key navigation, `@` file picker, and input token highlighting.
- Assistant markdown rendered while streaming (per-block); markdown tables fit terminal width; `--resume` replays assistant turns as markdown.
- Built-in fake LLM provider for tests/dev.
- Multi-arch (x86_64 + arm64) system release image build in CI.

### Changed

- Memory recall quality: recency and graph signals are demoted to tail supplements so direct FTS/vector matches win and survive single-shot recall (#51).
- LLM: route MiniMax through the anthropic-compatible endpoint and drop the OpenAI-compat band-aid patches; harden MiniMax-M2.7 (empty-turn retry, unknown-error retry, thinking/temp/max_tokens, overload backoff); recover tool-call turns that close the stream without `[DONE]`.
- LLM: use ruby_llm `before_message`/`after_message` (`on_new`/`on_end` deprecated); resolve provider once.
- Human-in-loop: wait on approvals/clarify instead of failing; `shell` tool on by default.
- `question` tool combines prompt + options into a single `ui.ask` call.

### Fixed

- **Approval gate**: bounded interruptible wait with auto-deny on expiry (24h -> 15min); an abandoned approval no longer parks a worker thread (which previously froze Puma) (#55, fixes #54). Earlier W1 fix also released the approval-parked worker on cancel/timeout, plus a skill-ref TOCTOU (W3).
- Interactive prompts work mid-turn (`run_in_terminal`); clarify/question no longer drop prompts on the API path; API accepts image-only runs (blank input + attachments).
- Per-run `EventBus` isolation (no cross-run event/output bleed); `run.completed` always carries final output on non-streaming runs.
- SSE idle watchdog no longer kills long silent tool calls.
- Local Ruby programming errors are classified non-retryable.
- First-run setup UX; `doctor` is provider-aware and reports migration/provider-key health correctly; tools listing and dropdown/help polish.
- CLI bughunt batch (B1-B8): reset cancel token each turn so Ctrl-C no longer poisons the session; single `ToolExecutor` sink counts/persists streaming tool results; errored tools render red; loose markdown lists stay one streamed block; `/skills` descriptions word-wrap. Plus Ctrl-C interrupt double-message dedupe, Escape dismisses slash autocomplete, real Available list on unknown command, multi-line paste/resize repaint, and markdown prose word-wrap/headings/table fixes.
- `grep` accepts a file path (not only a directory); File API workspace rooted at tool cwd so artifacts download.

### Security

- Universal secure-by-default file attachment handling (#57): classify-by-magic in both directions, typed per-kind preambles, a no-multimodal warning, nonce-framed and defanged inline text, an `attachments.policy` knob, and a unified safety pipeline.
- SSRF guard always allows loopback hosts for the File API.

## [0.2.19] - 2026-06-04

Codebase audit follow-up: tool/message integrity, internal-contract fixes, and dead-code removal. Net −1578 LOC. Researched against industry practice (Anthropic/OpenAI tool-pairing, Claude Code, Vercel AI SDK, LangChain, Cline, ruby_llm).

### Fixed

#### Tool/message integrity
- Compaction (`Compressor#create_child_session`) and `Session::Forker` no longer drop assistant `metadata[:tool_calls]` / `token_count` when copying messages — strict providers (Anthropic/Bedrock) no longer 400 on orphaned tool pairs after resume. Shared `Session::Store#copy_into` does a faithful copy.
- `ToolPairSanitizer` predicate fixed: it now detects assistant tool calls via `metadata[:tool_calls]` (was checking `tool_call_id`, which assistant rows never carry — the guard was inert) and is id-aware (a paired trailing call is preserved; an unanswered one is trimmed).
- `PromptAssembler#build` runs a defensive pre-send tool-pair repair (mirrors Claude Code's pre-call sanitization), recovering sessions already corrupted by the above.
- `BedrockBearerClient#stream` emits the common chunk contract `{type:, text:, message_id:}` (via `InlineThinkFilter`, with `MESSAGE_COMPLETED` boundaries) and is wrapped in `with_retries`; the `chunk.is_a?(Hash)` fallbacks were removed from the UI now that all adapters are uniform.

#### Internal contracts
- `tools.web` / `tools.browser` now actually gate `webfetch`/`websearch`: tools declare their config gate via `Tools::Base#config_key` (single source of truth shared by the registry and the CLI), instead of name string-munging that never queried the shipped defaults. Closes a "web off but still on" security footgun. Removed the dead `tools.browser` key.
- `confirm(scope:)` is part of the UI contract on all adapters (`Base`/`CLI`/`Null`/`API`); interactive tool approvals no longer raise `ArgumentError: unknown keyword: :scope`.
- `RUBINO_HOME` is now the single source of truth for the home path (`config set/get`, `setup`, `doctor` and the server agree); resolution shared in `Config::Loader`.
- `run.attachments_downloaded` is only emitted when files were actually downloaded (no empty diagnostic event on plain chats).
- Defensive guard for upstream errors with a string-shaped `error` body (ruby_llm OpenAI streaming `parse_streaming_error`) — the real upstream message surfaces instead of a `TypeError: String does not have #dig method`.

### Removed (dead code, audit-verified, −1578 LOC)
- LSP subsystem (`lsp/`), parallel `Auth` module (superseded by `oauth/`), `Terminal::Composer` (superseded by Reline `UI::LineInput`), `Session::Exporter`, `Memory::ProjectMemory`/`UserProfile` (duplicated `Memory::Retriever`), `Context::CompactionPolicy` (duplicated `TokenBudget`), `Security::RiskClassifier` (per-tool risk is canonical), `Session::Forker` (unused; real fork is the API `parent_session_id` path), `FileSystemTool` + its `file_system` arms, the `snapshots/` subsystem + CLI `undo`/`redo` + config, the unused Recorder live `Queue`, and assorted orphaned methods.
- Kept (planned features, currently dormant, to be wired later): MCP, multi-agent (Build/Plan/Explore), plugin hooks.

## [0.1.0] - 2025-05-11

### Added

#### Core
- Agent loop with iteration budget and tool execution
- Interaction lifecycle state machine with 14 states
- Event bus for decoupling core from UI
- SQLite database with WAL mode (Sequel migrations)
- Session persistence (messages, tool calls, events)
- Context compaction with session lineage
- Summary builder with structured template
- Token budget management
- Tool pair sanitizer for compaction integrity

#### Agents
- Multi-agent architecture (Build, Plan, Explore, General)
- Agent router with @mention support
- Per-agent model, tools, permissions, and MCP scoping
- Hidden utility agents (compaction, title)

#### Tools (15 built-in)
- file_system (read/write/list/exists)
- edit (exact string replacement)
- grep (ripgrep-backed regex search)
- glob (file pattern matching)
- git (status/diff/log/branch/show)
- github (PRs/issues/reviews via gh CLI or API)
- shell (command execution with allowlist)
- ruby (code evaluation)
- apply_patch (unified diff application)
- webfetch (URL content retrieval)
- websearch (Tavily/SearXNG/DuckDuckGo)
- question (interactive user queries)
- todowrite (task tracking)
- lsp (go_to_definition, references, hover, symbols, diagnostics)
- skill (on-demand skill loading)

#### MCP
- ruby_llm-mcp integration
- stdio, SSE, and streamable HTTP transports
- MCPToolWrapper for seamless tool registration
- Per-agent MCP server scoping
- OAuth 2.1 with PKCE for remote MCP servers

#### Memory
- Persistent memory store (7 kinds)
- Auto-extraction from conversations
- Jaccard similarity deduplication
- User profile and project memory
- Memory retriever with char limits
- Pre-compaction flush

#### Jobs
- SQLite-backed job queue
- Inline/manual/worker modes
- Retry with exponential backoff
- Job run auditing
- 5 built-in handlers (extract, summarize, compact, cleanup, index)

#### Security
- Pattern-based approval policy (allow/ask/deny)
- Wildcard matching on tool calls and paths
- Doom loop detection (3x identical calls)
- Command allowlist
- Risk classifier

#### Skills
- SKILL.md files with YAML frontmatter
- Multi-location discovery
- Lazy content loading
- SkillTool for agent access

#### Commands
- Custom slash commands from Markdown files
- $ARGUMENTS and positional params ($1-$9)
- Shell output injection (!`command`)
- File content injection (@path)
- Built-in: /help, /commands, /skills, /exit

#### Plugins
- 46 hook points across all subsystems
- File-based plugin loading from .rubino/plugins/
- Rubino.plugin DSL

#### UI
- CLI adapter (TTY gems)
- Null adapter (testing)
- API adapter (structured events)
- Rich TUI with alternate screen buffer
- 4 themes (default, dark, light, monokai)
- Customizable keybinds
- Input history

#### Server
- JSON API server (WEBrick)
- REST endpoints for sessions, messages, tools, memory, jobs
- SSE event streaming (/events)
- Optional Basic Auth

#### Auth
- OAuth 2.1 client with PKCE
- Provider authentication (/connect flow)
- Token persistence (~/.rubino/oauth_tokens.json)
- GitHub, OpenAI, Anthropic, Google providers

#### Configuration
- YAML config with defaults
- Enhanced loader: multi-layer precedence
- Environment variable substitution ({env:VAR})
- File content inclusion ({file:path})
- Remote/managed config for enterprise
- RUBINO_* env var overrides

#### LSP
- JSON-RPC stdio client
- 37 language servers configured
- Auto-detection by file extension
- Operations: definition, references, hover, symbols, diagnostics
- LspTool for agent access

#### Other
- Session undo/redo via internal git snapshots
- Session forking at any message
- Session export (Markdown/JSON)
- Image support for vision models
- Custom user-defined tools (Ruby DSL)
- Code formatters (auto-format after edits)
- Network proxy support (HTTP/HTTPS/SOCKS)
- GitHub integration (gh CLI + REST API)
- Project context file discovery (.rubino.md, AGENTS.md, etc.)
