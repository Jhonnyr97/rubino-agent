# Architecture

## Overview

rubino is a micro agent that runs on a PC or inside a VM. It follows a
layered architecture with strict separation of concerns:

```
Presentation Layer     →  CLI, TUI, JSON API Server
Orchestration Layer    →  Agent Router, Interaction Lifecycle
Core Layer             →  Agent Loop, Context, Memory, Jobs, Tools
Infrastructure Layer   →  LLM Adapter, Database, MCP, OAuth
```

## Key Design Principles

1. **All output goes through UI** — No `puts`/`print` in core modules
2. **LLM is isolated** — Only `LLM::RubyLLMAdapter` talks to ruby_llm
3. **SQLite is the single database** — Sessions, memory, jobs, events
4. **Event-driven** — Core emits events, UI/plugins subscribe
5. **Plugin hooks** — 38 declared extension points for customization (design surface; few are wired today)
6. **Config is not architecture** — Configuration describes what; architecture decides how

## Module Map

### `agent/`
Multiple agent types and @mention routing exist as a design surface; the
micro agent runs a single agent by default and multi-agent routing is dormant.
- `AgentRegistry` — Defines all agent types (build, plan, explore, general, utility)
- `Router` — Routes input to appropriate agent via @mention
- `Definition` — Agent type with model, tools, permissions, MCP scoping
- `Runner` — Top-level orchestrator for a user interaction
- `Loop` — Core LLM call + tool execution cycle
- `IterationBudget` — Prevents runaway loops
- `ToolExecutor` — Executes tools with approval and result formatting

### `interaction/`
- `Lifecycle` — Full turn lifecycle: input → memory → context → model → tools → persist → jobs
- `State` — State machine (idle → calling_model → executing_tools → finished)
- `EventBus` — Pub/sub for decoupling core from UI
- `Events` — All typed event constants

### `context/`
- `PromptAssembler` — Builds the full prompt from all sources
- `TokenBudget` — Calculates token usage and decides when to compact (`needs_compaction?`)
- `Compressor` — Orchestrates compaction (flush memory → split → summarize → lineage)
- `MessageBoundary` — Splits messages into head/middle/tail
- `SummaryBuilder` — Generates structured summaries via LLM
- `ToolPairSanitizer` — Keeps tool_call/result pairs intact
- `FileDiscovery` — Finds project context files (.rubino.md, AGENTS.md, etc.)

### `memory/`
- `Store` — CRUD for memories (7 kinds: user_profile, preference, fact, etc.)
- `Retriever` — Loads relevant memories for prompt inclusion
- `Extractor` — Pattern-based extraction from conversations
- `Deduplicator` — Jaccard similarity deduplication
- `Flusher` — Pre-compaction memory flush

### `session/`
- `Repository` — Session CRUD with prefix-matching find
- `Store` — Message persistence
- `Message` — Value object with to_context / to_row

Forking is not a dedicated class: a new session inherits history via the
API's `parent_session_id` path.

### `jobs/`
- `Queue` — SQLite-backed job queue with priority and scheduling
- `Runner` — Executes jobs, records runs
- `Worker` — Polling loop for background processing
- `Registry` — Maps job types to handler classes
- Handlers: ExtractMemory, SummarizeSession, CompactSession, Cleanup, IndexMemory

### `tools/`
- `Base` — Abstract tool interface (name, description, input_schema, risk_level, call)
- `Registry` — Singleton registry with enable/disable
- `Result` — Structured result (success/error/denied)
- 23 built-in tools + custom tool loader + formatter integration
- `CustomToolLoader` — DSL for user-defined tools

### `llm/`
- `RubyLLMAdapter` — Wraps ruby_llm (chat, stream, structured output)
- `ProviderResolver` — Auto-detects provider from model name
- `ModelRegistry` — Known models with context windows
- `ContentBuilder` — Multipart content for vision (text + images)

### `mcp/`
MCP support is present as a design surface but dormant in the current
micro-agent build.
- `Manager` — Manages multiple MCP client connections
- `MCPToolWrapper` — Wraps MCP tools into Tools::Base interface

### `security/`
- `ApprovalPolicy` — Decides allow/ask/deny per tool call
- `PatternMatcher` — Wildcard pattern matching for permissions
- `DoomLoopDetector` — Detects repeated identical tool calls
- `CommandAllowlist` — Pre-approved shell commands

### `plugins/`
- `Registry` — Central hook registry; the hook set (38 points) is declared in
  `plugins.rb` as a design surface, with few hooks wired today
- Loaded from `.rubino/plugins/`

### `skills/`
- `Skill` — Parsed SKILL.md with YAML frontmatter
- `Registry` — Discovery from configured paths
- `SkillTool` — Tool for on-demand skill loading

### `commands/`
- `Command` — Parsed command.md with template rendering
- `Loader` — Discovery from configured paths
- `Executor` — Handles slash commands and built-ins

### `api/`
- `Server` — Rack + Puma boot
- `Router` — pattern-based dispatcher
- `Middleware::{Auth,ErrorHandler,JsonParser}` — Bearer auth, typed-error mapping, JSON body parsing
- `Operations::*` — request handlers (sessions, runs, approvals, clarifications, skills, models, files, cron jobs, oauth)

### `oauth/`
- `Provider` (+ `Github`, `Google`) — provider abstraction with PKCE auth flow
- `Registry` — process-wide registry hydrated from config
- `ConnectionRepository` — encrypted token persistence (AES-256-GCM via `TokenEncryptor`)

### `config/`
- `Loader` — Basic YAML loader
- `EnhancedLoader` — Multi-layer precedence with substitutions
- `RemoteConfig` — Enterprise remote config fetching
- `Configuration` — Typed accessors for all config sections
- `Writer` — Persists config changes
- `Defaults` — All default values

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
  ├─→ Agent::Router (if @mention)
  │     └─→ Select agent definition
  │
  └─→ Interaction::Lifecycle
        │
        ├─ Persist user message
        ├─ Load memory (Retriever)
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
        │    │    ├─ Run plugin hooks
        │    │    └─ Loop back to LLM
        │    └─ Final text response
        │
        ├─ Persist session
        ├─ Enqueue jobs (extract memory, summarize)
        └─ Emit events → UI + SSE clients
```
