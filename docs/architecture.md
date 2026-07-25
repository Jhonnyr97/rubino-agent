# Architecture

## Overview

rubino is a lightweight agent that runs on a PC or inside a VM. It follows a
layered architecture with strict separation of concerns:

```
Presentation Layer     →  CLI, JSON API Server
Orchestration Layer    →  Agent Router, Interaction Lifecycle
Core Layer             →  Agent Loop, Context, Memory, Jobs, Tools
Infrastructure Layer   →  LLM Adapter, Database, MCP, OAuth
```

## Key Design Principles

1. **All output goes through UI** — No `puts`/`print` in core modules
2. **LLM is isolated** — Only `LLM::RubyLLMAdapter` talks to ruby_llm
3. **SQLite is the single database** — Sessions, memory, jobs, events
4. **Event-driven** — Core emits events, UI subscribes
5. **Config is not architecture** — Configuration describes what; architecture decides how

## Module Map

### `agent/`
Multi-agent ships: the model delegates to background subagents via the `task`
tool, and the user switches the primary agent on the `/` slash channel (`/agent`,
a bare `/<name>`, or Tab). There is no `@mention` agent routing — `@` is the
workspace file picker. See [agents.md](agents.md).
- `AgentRegistry` — Defines the built-in agents (build, plan, explore, general, compaction, title; `utility` is a *type*, not an agent name)
- `Definition` — Agent type with model, tools, permissions, MCP scoping
- `Runner` — Top-level orchestrator for a user interaction
- `Loop` — Core LLM call + tool execution cycle
- `IterationBudget` — Prevents runaway loops
- `ToolExecutor` — Executes tools with approval and result formatting

### `interaction/`
- `Lifecycle` — Full turn lifecycle: input → memory → context → model → tools → persist → jobs
- `EventBus` — Pub/sub for decoupling core from UI
- `Events` — All typed event constants
- `CancelToken` — Thread-safe cooperative cancellation flag threaded through a turn
- `InputQueue` — Thread-safe hand-off of typed-while-busy input to the REPL loop (queue-by-default type-ahead)
- `Polishing` — Best-effort post-turn memory-extract/skill-distill drain, off the turn's critical path
- `Probe` — Ephemeral, read-only side-question against the current session (`/probe`)

### `context/`
- `PromptAssembler` — Builds the full prompt from all sources
- `TokenBudget` — Calculates token usage and decides when to compact (`needs_compaction?`)
- `Compressor` — Orchestrates compaction (split → summarize → lineage; the review fork already mines memory inter-turn, so there is no pre-compaction memory flush)
- `MessageBoundary` — Splits messages into head/middle/tail
- `SummaryBuilder` — Generates structured summaries via LLM
- `ToolPairSanitizer` — Keeps tool_call/result pairs intact
- `FileDiscovery` — Finds project context files (.rubino.md, AGENTS.md, etc.)

### `memory/`
- `Store` — CRUD for memories (7 kinds: user_profile, preference, fact, etc.)
- `Backend` — Duck-typed pluggable backend contract (write / read / retrieve / admin); retrieval is `Memory::Backend#retrieve`, not a dedicated Retriever class
- `Backends` — name→class backend registry, selected by `memory.backend` (default `sqlite`, the FTS5/graph-lite backend)
- `Deduplicator` — Jaccard similarity deduplication
- `EntityExtractor` — Deterministic, zero-dependency entity extraction for the graph-lite layer (no LLM/NER)
- `SqliteGraph` — Graph-lite mixin (entities + edges) blending a bounded 1-hop traversal into retrieval
- `ThreatScanner` — Scans every memory write for injection/exfiltration before it can splice into a future prompt

Extraction is no longer a dedicated class: durable facts are mined agentically
by the warm-prefix review fork (`Jobs::Handlers::BackgroundReviewJob`) writing
through the `memory` tool. See [memory.md](memory.md#how-facts-are-extracted-write-path).

### `session/`
- `Repository` — Session CRUD with prefix-matching find
- `Store` — Message persistence
- `Message` — Value object with to_context / to_row
- `Exporter` — Serializes a session transcript to markdown (`/export`, `rubino sessions show`)
- `Picker` — Interactive arrow-key resume picker (bare `rubino sessions` / `/sessions` on a TTY)

Forking is not a dedicated class: a new session inherits history via the
API's `parent_session_id` path.

### `jobs/`
- `Queue` — SQLite-backed job queue with priority and scheduling
- `Runner` — Executes jobs, records runs
- `Worker` — Polling loop for background processing
- `Registry` — Maps job types to handler classes
- `Handlers::BackgroundReviewJob` — the only handler: warm-prefix review fork mining memory + skills. There is no SummarizeSession/CompactSession/CleanupSessions handler — compaction runs inline (`Interaction::Lifecycle#check_and_compact`) and session cleanup is `CleanupService`, not a job handler
- `Scheduler` — In-process cron scheduler (rufus-scheduler) that fires enabled cron jobs
- `CronJobRepository` — CRUD for cron job definitions
- `WebhookDelivery` — POSTs cron-job results to a configured webhook with HMAC signing, idempotency, and retries

### `tools/`
- `Base` — Abstract tool interface (name, description, input_schema, risk_level, call)
- `Registry` — Singleton registry with enable/disable
- `Result` — Structured result (success/error/denied)
- The built-in tools (authoritative, drift-checked count and list in [tools.md](tools.md)) + custom tool loader + formatter integration
- `CustomToolLoader` — loads user-authored tools (the `Rubino.define_tool` DSL) from `~/.rubino/tools/`

### `compression/`
Compresses large tool-output content before it lands in context — a distinct
concern from `Context::Compressor` (which compacts whole-conversation history).
- `Compressor` — Entry point that routes a piece of tool-read content to a compression strategy
- `ContentRouter` — The single content-routing seam every tool output passes through
- `DiffCompressor`, `JsonCompressor`, `LogCompressor` — Format-specific compressors
- `*CodeSkeleton` (Ruby/Python/TypeScript/TSX/JavaScript/tree-sitter) — Language-aware code-to-skeleton compressors

### `attachments/`
- `Policy` — Reads the secure-by-default knobs from config (`attachments.policy`: classification + the `max_file_bytes` cap)
- `Classify` — Deterministic, no-LLM attachment classifier with a fail-closed default
- `Defang` — Structural prompt-injection defense for inlined untrusted file content

### `documents/`
Non-image file → markdown conversion (PDF, docx, xlsx, pptx) used by `read`/`web_fetch`/attachments.
- `Registry` — Ordered registry of document converters (mirrors `Tools::Registry`'s shape)
- `Html` — The HTML → Markdown core (markitdown-style conversion)

### `llm/`
- `RubyLLMAdapter` — Wraps ruby_llm (chat, stream, structured output)
- `ProviderResolver` — Auto-detects provider from model name
- `ModelCatalog` — Enumerates the model ids the ruby_llm registry knows for a provider (powers `/model`)
- `ContentBuilder` — Multipart content for vision (text + images)

### `mcp/`
Experimental — booted at chat startup when `mcp.servers` is configured
(see [mcp.md](mcp.md)).
- `Manager` — Manages multiple MCP client connections
- `MCPToolWrapper` — Wraps MCP tools into Tools::Base interface

### `security/`
- `ApprovalPolicy` — Decides allow/ask/deny per tool call
- `PatternMatcher` — Wildcard pattern matching for permissions
- `DoomLoopDetector` — Detects repeated identical tool calls
- `CommandAllowlist` — Pre-approved shell commands
- `HardlineGuard` — The non-yolo-overridable floor of always-blocked destructive commands
- `Sandbox` — OS-level write-jail (Landlock/Seatbelt) confining tool writes to the workspace
- `ContentScanner` — Prompt-injection/promptware scanner for externally-loaded `.md` content (agents, skills, commands, context files) — see [markdown-extensions.md](markdown-extensions.md#security)
- `Redactor` — Masks secret-shaped values (API keys, tokens) in tool output before it reaches the model or the transcript

### `skills/`
- `Skill` — Parsed SKILL.md with YAML frontmatter
- `Registry` — Discovery from configured paths
- `SkillTool` — Tool for on-demand skill loading
- `Installer` — Installs skills from a git repo (`rubino skills install`)
- `ContentPreprocessor` — Template-variable substitution + optional inline-shell expansion for skill bodies

### `commands/`
- `Command` — Parsed command.md with template rendering
- `Loader` — Discovery from configured paths
- `Executor` — Handles slash commands and built-ins
- `BuiltIns` — Single source of truth for built-in slash command names + descriptions (`/help`, tab-completion, and [commands.md](commands.md) all read this)

### `api/`
- `Server` — Rack + Puma boot
- `Router` — pattern-based dispatcher
- `Middleware::{Auth,ErrorHandler,JsonParser}` — Bearer auth, typed-error mapping, JSON body parsing
- `Middleware::RateLimit` — Token-bucket rate limiter (per-IP for open routes, per-bearer-token for authenticated ones)
- `Middleware::Observability` — Outermost middleware: per-request metrics + one JSON log line
- `Operations::*` — request handlers (sessions, runs, approvals, clarifications, skills, models, files, cron jobs, oauth)

### `run/`
A `Run` is one user-input → assistant-response execution driven from the HTTP API or a cron tick (as opposed to the interactive CLI REPL, which drives `Agent::Runner` directly).
- `Executor` — Runs an `Agent::Runner` in a background thread, persisting per-run events
- `Repository` — Run CRUD
- `Recorder` — Bridges `Interaction::EventBus` to per-run persisted events
- `EventStore` — Persists per-run events for SSE replay (Last-Event-ID) and audit
- `ApprovalGate` / `GateRegistry` — Synchronizes async HTTP approval/clarification decisions with the in-thread run loop
- `AttachmentDownloader` — Fetches URL attachments passed on a run
- `SessionApprovalCache` — Remembers approval decisions that should survive past the current call

### `oauth/`
- `Provider` (+ `Github`, `Google`) — provider abstraction with PKCE auth flow
- `Registry` — process-wide registry hydrated from config
- `ConnectionRepository` — encrypted token persistence (AES-256-GCM via `TokenEncryptor`)

### `config/`
- `Loader` — Layered YAML loader
- `Configuration` — Typed accessors for all config sections
- `Writer` — Persists config changes
- `Validator` — Set-time schema validation for `config set` (rejects unknown keys and type/format mismatches at write time)
- `ReasoningPrefs` — Single source of truth resolving reasoning/thinking prefs from config (shared by adapter gate + CLI render)
- `Defaults` — All default values (the authoritative schema)

### `database/`
- `Connection` — SQLite + WAL mode via Sequel
- `Migrator` — Versioned migrations

### `ui/`
- `Base` — Abstract interface (info, error, stream, table, ask, confirm, etc.)
- `CLI` — TTY-based terminal output
- `Null` — Silent adapter for testing
- `API` — Structured event collector

## Data Flow

```
User Input
  │
  ├─→ Commands::Executor (if /command)
  │     └─→ Render template → feed to agent
  │
  ├─→ ActiveAgent (if /agent, /<name>, or Tab)
  │     └─→ Select primary agent definition
  │
  └─→ Interaction::Lifecycle
        │
        ├─ Persist user message
        ├─ Load memory (Memory::Backend#retrieve)
        ├─ Extract images (ContentBuilder)
        ├─ Build context (PromptAssembler)
        ├─ Check token budget (TokenBudget)
        ├─ Compact if needed (Compressor)
        │
        ├─ Agent::Loop
        │    ├─ Call LLM (RubyLLMAdapter)
        │    ├─ Stream to UI
        │    ├─ If tool_calls:
        │    │    ├─ Check permissions (ApprovalPolicy)
        │    │    ├─ Check doom loop (DoomLoopDetector)
        │    │    ├─ Execute tool (ToolExecutor)
        │    │    └─ Loop back to LLM
        │    └─ Final text response
        │
        ├─ Persist session
        ├─ Enqueue post-turn jobs (review fork: memory + skills)
        └─ Emit events → UI + SSE clients
```
