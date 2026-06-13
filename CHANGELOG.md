# Changelog

## [Unreleased]

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
