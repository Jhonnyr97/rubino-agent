# AGENTS.md — rubino

Onboarding for anyone (human or AI) working on this codebase.

## Vision

`rubino` is a **micro agent**: a small, self-contained Ruby gem that runs an LLM-driven coding/automation agent *on the machine where the work happens* — the user's PC or a VM. You drop it onto that machine and it works there, reachable over a clean HTTP API and a CLI. It executes conversation turns with tool calls, streams events, manages skills, and persists sessions/memory in a single SQLite file. It can be embedded as a library, run as a CLI, or run as a small service behind a REST gateway.

It is a lightweight agent, **not a heavy framework**. We pick the few primitives that have real value and skip everything else. Scope discipline is part of the product.

## Non-goals (explicit)

These decisions are permanent. Reopen only with a written justification.

- **No dual HTTP APIs.** One server, one versioned prefix (`/v1`). When we break, bump to `/v2`. Never aliases.
- **No multi-tenant inside one process.** One instance = one workspace = one identity. Multi-tenant deployments run N instances.
- **No dashboard / theme system / plugin hub.** The dashboard is whatever client consumes our API. We don't ship a UI server.
- **No skill catalog bundled.** Skills are user-supplied directories. We don't ship a catalog.
- **No compat layers.** Renamed something? Rename everywhere. Reshaped a response? Bump version.
- **No auto-update endpoints.** Deploy = gem update + restart. Period.
- **No backwards-compat shims, no _deprecated suffixes, no "legacy" anything.**

## Architectural rules (load-bearing)

These are load-bearing. When a PR violates them, it is the PR that gets redone.

1. **One interface per concept.** One `LLM::Adapter`, one `Tools::Base`, one `Memory::Store`. Variants are subclasses, not parallels.
2. **No PORO commands in `lib/`.** Domain logic on models/repositories; orchestration as class methods. No `app/services/Foo::DoThingCommand`.
3. **No optional-magic params.** Signatures explicit. If long, refactor responsibilities, don't add `**opts`.
4. **Schema-validated input at boundaries** (HTTP, CLI, MCP). Internals trust types.
5. **Typed errors only.** `raise NotFoundError, "session"` not `raise "session not found"`.
6. **Test contracts, not implementation.** Internals change without breaking tests, not vice versa.
7. **Structured logging from day one.** JSON-line. No `puts`/`pp` outside the UI layer. Logger DI-injected.
8. **No global singletons.** Config flows from the main loop into everything via constructor.
9. **Handlers stay thin.** Endpoint >30 LOC → extract `Operation` class.
10. **Less code, less bugs.** A refactor is good if it deletes net lines. Distrust preparatory abstractions (PORO/Result/custom errors before you need them).

## Tech stack

| Layer | Choice | Why |
|---|---|---|
| LLM | `ruby_llm ~> 1.0` (thin wrap) | One mature gem covering OpenAI/Anthropic/Gemini/Bedrock. We never call providers directly. |
| MCP | `ruby_llm-mcp ~> 0.8` | Pairs natively with `ruby_llm`. |
| HTTP server | `rack` + `puma` | Standard. WEBrick is gone. |
| DB | `sequel` + `sqlite3` | One file, zero ops. Postgres later if multi-writer matters. |
| Schema | `dry-schema` | Boundary validation. |
| Scheduler | `rufus-scheduler` | Cron syntax, in-process. |
| Config | `dry-configurable` | Already in use. |
| CLI | `thor` | Already in use. |
| Autoload | `zeitwerk` | Already in use. |
| CLI UI | `tty-*` + `reline` | The interactive `rubino chat` prompt (history, completion, multi-line editing). |

`ruby_llm` is the foundation. `LLM::RubyLLMAdapter` is a thin wrapper: it configures `RubyLLM`, delegates `chat`/`stream`/`model_info`, and exposes nothing the underlying gem can't already do. **If you find yourself adding business logic to the adapter, push it into the run loop instead.**

## Layout

```
lib/rubino/
  agent/         # run loop, lifecycle, multi-agent routing
  api/           # HTTP gateway (Rack app, middleware, operations)
  cli/           # thor commands
  config/        # dry-configurable
  context/       # compaction, prompt assembly
  interaction/   # conversation lifecycle primitives
  jobs/          # scheduler + worker (cron)
  llm/           # ruby_llm adapter + model registry
  mcp/           # MCP client + tool wrapper
  memory/        # Memory::Store + extractors + retrievers
  oauth/         # OAuth providers + connection storage
  security/      # approval policy, sandboxing
  session/       # repository + persistence
  skills/        # SKILL.md loader
  tools/         # built-in tools
  ui/            # cli/null/api stub UIs
```

## Surfaces this project exposes

- **HTTP API** (`/v1/*`) — the canonical interface. See `docs/api/v1.md`.
- **CLI** — `rubino {setup,chat,prompt,server,config,memory,sessions,jobs,tools,doctor,version}`.
- **Library** — `require "rubino"; Rubino.run(...)`.

The interactive CLI ships as part of `rubino chat`. Multi-agent routing, MCP, and plugin hooks are designed in but not fully wired yet.

## Working on this codebase

- Read `docs/architecture.md` for the bigger picture.
- Read `docs/api/v1.md` for HTTP contract.
- Read `docs/oauth-providers.md` for OAuth design.
- Run `bundle exec rspec` before pushing.
- Don't commit if rubocop fails.

## Git/commit conventions

- Conventional commits welcome but not required.
- No AI attribution lines in commit messages.
- Small commits over big ones. A commit that touches 30 files needs a justification.
