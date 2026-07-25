# MCP Integration

> **Status: EXPERIMENTAL.** stdio servers are wired end-to-end (connect at chat boot, tools/resources/prompts registered, `doctor`/`tools`/in-chat `/mcp` surfaces). Resources and prompts are per-server capability-gated — a tools-only server registers neither. `sse`/`streamable` configs are forwarded to [ruby_llm-mcp](https://github.com/patvice/ruby_llm-mcp) but less battle-tested, and OAuth is **not implemented** on the rubino side (see below). Don't depend on it in production yet.

rubino supports the [Model Context Protocol](https://modelcontextprotocol.io/) via [ruby_llm-mcp](https://github.com/patvice/ruby_llm-mcp).

## Configuration

Configuring at least one server under `mcp.servers` in `config.yml` **is the opt-in** — there is no separate feature flag to flip. Set `mcp.enabled: false` to switch MCP off without deleting the server definitions.

```yaml
mcp:
  # enabled: false        # optional kill switch; defaults to true when servers exist
  servers:
    # Local server via stdio
    filesystem:
      transport: stdio
      command: "npx"
      args: ["@modelcontextprotocol/server-filesystem", "/path/to/project"]
      env:
        DEBUG: "1"

    # Remote server via SSE
    remote_api:
      transport: sse
      url: "https://mcp.example.com/sse"
      headers:
        Authorization: "Bearer {env:MCP_TOKEN}"

    # Remote server via streamable HTTP
    streaming_api:
      transport: streamable
      url: "https://mcp.example.com/api"
      timeout: 15000
```

## Transport Types

| Transport | Use Case | Config |
|-----------|----------|--------|
| `stdio` | Local MCP servers, CLI tools | `command`, `args`, `env` |
| `sse` | Web-based servers with Server-Sent Events | `url`, `headers`, `oauth` |
| `streamable` | HTTP servers with streaming support | `url`, `headers`, `oauth` |

## How It Works

1. At chat boot (and in `rubino tools`), `MCP::Manager` connects to all configured servers **in parallel** (#576), so one hanging server no longer serializes startup — best-effort: a server that fails to start prints a warning and is skipped, it never blocks the session
2. Each server's tools are wrapped in `MCPToolWrapper` (adapts to `Tools::Base` interface), forwarding the server-declared input schema so the model calls them with the right argument names. Every wrapped tool is external code, so its risk is **fixed** at `medium` (`risky?: true`, `sandbox: none`) regardless of anything the server itself claims — this is not configurable per-tool or per-server — and its output is always run through the `:shell` secret-redaction profile (the same one shell command output uses), an explicit fail-safe for output originating outside rubino's control
3. Wrapped tools are registered in `Tools::Registry` with a prefix (`servername_toolname`), capped at 64 characters (`MCPToolWrapper::MAX_NAME_LENGTH`) so a hostile/buggy server can't register an arbitrarily long name that would blow up the `tools` table or get the request rejected by the provider; additionally, when the server advertises the `resources` or `prompts` capability, a per-server `<server>_resources` / `<server>_prompts` utility tool is registered alongside the wrappers (see [Resources & Prompts](#resources--prompts))
4. The agent can use MCP tools like any built-in tool; a failed MCP call (including a server-side argument rejection) surfaces as an `Error: …` tool result and renders ✗ like any failed built-in tool. To keep external code visible, an MCP tool's **display label** is suffixed with its source — the live tool card and the approval card both show `<bare> (mcp:<server>)` (e.g. `echo (mcp:chaos)`), so you can tell at a glance that an out-of-process server is running (#582). The model-facing tool name is unchanged.
5. `ruby_llm-mcp`'s own log lines (including everything a stdio server prints on its stderr) go to `<home>/logs/mcp.log`, never to stdout — one-shot `rubino prompt` output stays machine-readable

MCP tools are dynamic — they come from whatever servers you configure — so they are not part of the drift-checked built-in tool list in [tools.md](tools.md) and have no `tools.<key>` config gate; disable a server (`/mcp <server> off` for the session, or set `mcp.enabled: false`) to remove its tools.

## Resources & Prompts

When an MCP server advertises `resources` or `prompts` in its capabilities, rubino registers a per-server utility tool for each, following the Hermes convention of exposing them as model tools (contrast: Claude Code surfaces resources and prompts as user-driven `@`-mentions and `/`-commands; rubino chose the model-tool route for uniformity with the rest of the toolset).

Both tools follow the same per-server lifecycle as tool wrappers (`/mcp <server> on/off`, `/mcp reload`) and are dropped when the server is stopped or deregistered (see `Manager#deregister_tools`, which keys on `#mcp_server` — same seam as MCPToolWrapper).

### `<server>_resources`

Named `<server>_resources`, truncated to 64 characters if needed (same cap as `MCPToolWrapper::MAX_NAME_LENGTH`). The model calls it with the `action` parameter:

| action | params | returns |
|--------|--------|---------|
| `"list"` | — | One line per resource: `uri — name (mime_type) — description` |
| `"read"` | `uri` (required) | The resource's content as plain text; errors on unknown uri or empty content |

Risk: medium, external (`risky?: true`, sandbox: `none`). Redaction: `:shell`.

### `<server>_prompts`

Named `<server>_prompts`, truncated to 64 characters (same cap). The model calls it with the `action` parameter:

| action | params | returns |
|--------|--------|---------|
| `"list"` | — | One line per prompt template: `name — description (args: name1, name2?)` |
| `"get"` | `name` (required), `arguments` (optional, free-form object) | Rendered prompt messages (via `ruby_llm-mcp`'s `prompt.fetch`, NOT a chat turn), one line per message: `role: content` |

Risk: medium, external (`risky?: true`, sandbox: `none`). Redaction: `:shell`.

### Capability-gating

A tools-only MCP server that does not advertise `resources` or `prompts` registers NEITHER utility tool — no dead tools, no "Method not found" errors. The gating is checked in `Manager#register_server_tools` per server at registration time.

## Per-Agent Scoping

Control which MCP servers each agent can access in `config.yml`:

```yaml
agents:
  explore:
    mcp_servers: ["filesystem"]   # Only filesystem MCP
  build:
    mcp_servers: all              # All MCP servers (default)
  plan:
    mcp_servers: []               # No MCP tools
```

An agent with no `mcp_servers` key sees every server. The YAML string `all` is normalized to `:all`. The scoping is enforced in `Agent::Definition#resolved_tools` — the single seam every consumer of an agent's tool set (chat lifecycle, prompt assembler) goes through — so a scoped agent's model request simply does not contain the out-of-scope servers' tool definitions. The filter drops ANY tool that responds to `#mcp_server` (both `MCPToolWrapper` wrappers and the `<server>_resources` / `<server>_prompts` utility tools), so per-agent scoping covers resources and prompts for free — no separate config needed.

In code (an explicit value here wins over config):

```ruby
Rubino::Agent::Definition.new(
  name: "secure_agent",
  mcp_servers: ["internal_api"]  # Only this server's tools
)
```

## Authentication

Remote-server credentials are passed through config: use `headers` (e.g. `Authorization: "Bearer {env:MCP_TOKEN}"`) or the server process `env` for stdio servers.

An `oauth` hash on a remote server — both `sse` and `streamable` transports carry it (`Manager#build_client_options` forwards `config[:oauth]` in the shared `sse`/`streamable` branch) — is forwarded verbatim to `ruby_llm-mcp`. rubino itself implements **no** OAuth flow: there is no PKCE/browser handshake and no rubino-side token storage (no `~/.rubino/oauth_tokens.json`). Whatever OAuth behavior you get is whatever your installed `ruby_llm-mcp` version provides; treat it as not yet supported.

## Managing from Chat

`/mcp` is the in-chat management surface ([commands.md](commands.md#mcp-servers-mcp)):

```
/mcp                 # server list: name, transport, reachability, tool count
/mcp <server>        # drill-in: transport + command/url, health, registered tools, last start error
/mcp <server> off    # stop the client and deregister its tools for this session
/mcp <server> on     # (re)start the client and register its tools
/mcp reload          # re-read config.yml and reconnect every server (no chat restart needed)
```

`/mcp`'s server list glyphs each server by health: green `●` **reachable**, yellow `⚠` **degraded** (#575 — the process is alive but a protocol call such as `tools/list` failed, so it's up but not fully serving), and a stopped/failed server shows its last start error in the drill-in. `off`/`on` are session-scoped — config is untouched. `/mcp reload` is how a server added to `config.yml` mid-session becomes usable. When servers are configured, `/status` includes an `mcp` line (`2 servers · 1 reachable · 14 tools`).

## Manual Management

```ruby
# Start all servers
manager = Rubino::MCP::Manager.new
manager.start_all!

# Get tools for a specific agent (mcp_servers scoping applied)
tools = agent_definition.resolved_tools

# Health check
manager.health_check
# => [{ name: "filesystem", alive: true }, { name: "api", alive: false }]

# Stop a server
manager.stop_server("filesystem")

# Stop all
manager.stop_all!
```

## CLI

```bash
rubino doctor   # "Optional (MCP servers, experimental)" section: per-server reachability.
                # Informational only — an unreachable MCP server never fails doctor.
rubino tools    # "MCP Tools (experimental)" section: prefixed servername_toolname rows
                # per server, after the built-in table.
```
