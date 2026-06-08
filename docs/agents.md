# Multi-Agent System

rubino supports multiple agent types, each with their own model, tools, permissions, and system prompts.

> **Status:** Multi-agent selection is **not yet wired by default** (planned). The
> machinery described here exists — `Agent::Router`, `Agent::Definition`,
> `AgentRegistry`, and the `agent_definition:` plumbing through the runner and
> lifecycle — but no call site currently passes an agent definition, so the
> single default (build) agent handles every turn. This document describes the
> intended design and usage.

## Built-in Agents

| Agent | Type | Access | Description |
|-------|------|--------|-------------|
| **build** | primary | Full tools | Default development agent. Can read, write, execute. |
| **plan** | primary | Read-only | Analysis and planning. Edits/shell require approval. |
| **explore** | subagent | Read-only | Fast codebase search and navigation. |
| **general** | subagent | Full tools | Complex multi-step tasks. |
| **compaction** | utility | None | Internal: compresses context. Hidden. |
| **title** | utility | None | Internal: generates session titles. Hidden. |

## Switching Agents

In the TUI, press **Tab** to cycle through primary agents.

In chat, use `@mention`:

```
you > @explore Where is the database connection configured?
you > @plan How should we restructure the auth module?
you > @general Research the top 5 Ruby testing frameworks and compare them
```

## Agent Definition

Each agent has:
- **name** — Unique identifier
- **type** — `:primary` (user-switchable), `:subagent` (invokable), `:utility` (hidden)
- **model** — Override the default model (optional)
- **system_prompt** — Agent personality and instructions
- **tools** — `:all`, `:read_only`, or specific tool names
- **permissions** — Pattern-based overrides
- **mcp_servers** — Which MCP servers are accessible (`:all` or array)
- **max_turns** — Iteration limit
- **hidden** — Whether it appears in @mention autocomplete

## Custom Agents

### Via Config

```yaml
agents:
  security:
    type: subagent
    model: "anthropic/claude-sonnet-4-20250514"
    description: "Security-focused code review"
    system_prompt: |
      You are a security expert. Analyze code for vulnerabilities,
      injection risks, authentication flaws, and data exposure.
    tools: [read, grep, glob]
    mcp_servers: []
    permissions:
      "shell *": "deny"
      "write *": "deny"

  docs:
    type: subagent
    description: "Documentation writer"
    tools: [read, write, edit, grep, glob]
    permissions:
      "write *.md": "allow"
      "write *": "deny"
```

### Via Code

```ruby
Rubino::Agent::AgentRegistry.new.register(
  Rubino::Agent::Definition.new(
    name: "devops",
    type: :subagent,
    model: "openai/gpt-4.1",
    description: "Infrastructure and deployment specialist",
    system_prompt: "You are a DevOps engineer...",
    tools: [:read, :write, :edit, :shell, :git, :github],
    mcp_servers: ["kubernetes"],
    permissions: { "shell kubectl delete *" => "ask" }
  )
)
```

## Agent Routing

The `Agent::Router` handles:

1. **@mention detection** — `@explore query` routes to the explore agent
2. **Primary agent switching** — Tab key cycles through primary agents
3. **Default routing** — Unmentioned input goes to current primary agent

## Child Sessions

When a subagent is invoked, it operates in the context of the current session but can be configured to create a child session for isolation.

## Per-Agent Permissions

Each agent can override global permissions:

```ruby
Definition.new(
  name: "safe_agent",
  permissions: {
    "shell *" => "deny",       # No shell at all
    "write /etc/*" => "deny",   # No system file writes
    "git *" => "allow"         # Git is fine
  }
)
```

The `ApprovalPolicy` merges agent-specific permissions over global rules.
