# Changelog

## [Unreleased]

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

## [0.3.0] - 2026-06-06

Major capability release: the core conversation loop was ported 1:1 from the reference implementation (formalized LLM boundary, retry/backoff/fallback, degenerate-response recovery), background subagents became the default delegation path, the memory subsystem grew a pluggable backend contract with a tiny-Zep SQLite backend that is now the default, CLI gained image/file input and a scroll-native redesign, and a reference-aligned approval model (hardline floor, dangerous-pattern deny, prefix-derived rules) landed. Consolidated from `feature/subagent-view` (#48) plus #49-#58.

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
