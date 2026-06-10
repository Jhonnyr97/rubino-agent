# MCP Integration

> **Status: EXPERIMENTAL.** stdio servers are wired end-to-end (connect at chat boot, tools registered, `doctor`/`tools`/in-chat `/mcp` surfaces). `sse`/`streamable` configs are forwarded to [ruby_llm-mcp](https://github.com/patvice/ruby_llm-mcp) but less battle-tested, and OAuth is **not implemented** on the rubino side (see below). Don't depend on it in production yet.

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
| `sse` | Web-based servers with Server-Sent Events | `url`, `headers` |
| `streamable` | HTTP servers with streaming support | `url`, `headers`, `oauth` |

## How It Works

1. At chat boot (and in `rubino tools`), `MCP::Manager` connects to all configured servers — best-effort: a server that fails to start prints a warning and is skipped, it never blocks the session
2. Each server's tools are wrapped in `MCPToolWrapper` (adapts to `Tools::Base` interface), forwarding the server-declared input schema so the model calls them with the right argument names
3. Wrapped tools are registered in `Tools::Registry` with a prefix (`servername_toolname`)
4. The agent can use MCP tools like any built-in tool; a failed MCP call (including a server-side argument rejection) surfaces as an `Error: …` tool result and renders ✗ like any failed built-in tool
5. `ruby_llm-mcp`'s own log lines (including everything a stdio server prints on its stderr) go to `<home>/logs/mcp.log`, never to stdout — one-shot `rubino prompt` output stays machine-readable

MCP tools are dynamic — they come from whatever servers you configure — so they are not part of the drift-checked built-in tool list in [tools.md](tools.md) and have no `tools.<key>` config gate; disable a server (`/mcp <server> off` for the session, or set `mcp.enabled: false`) to remove its tools.

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

An agent with no `mcp_servers` key sees every server. The YAML string `all` is normalized to `:all`. The scoping is enforced in `Agent::Definition#resolved_tools` — the single seam every consumer of an agent's tool set (chat lifecycle, prompt assembler) goes through — so a scoped agent's model request simply does not contain the out-of-scope servers' tool definitions.

In code (an explicit value here wins over config):

```ruby
Rubino::Agent::Definition.new(
  name: "secure_agent",
  mcp_servers: ["internal_api"]  # Only this server's tools
)
```

## Authentication

Remote-server credentials are passed through config: use `headers` (e.g. `Authorization: "Bearer {env:MCP_TOKEN}"`) or the server process `env` for stdio servers.

An `oauth` hash on a `streamable` server is forwarded verbatim to `ruby_llm-mcp` — rubino itself implements **no** OAuth flow: there is no PKCE/browser handshake and no rubino-side token storage (no `~/.rubino/oauth_tokens.json`). Whatever OAuth behavior you get is whatever your installed `ruby_llm-mcp` version provides; treat it as not yet supported.

## Managing from Chat

`/mcp` is the in-chat management surface ([commands.md](commands.md#mcp-servers-mcp)):

```
/mcp                 # server list: name, transport, reachability, tool count
/mcp <server>        # drill-in: transport + command/url, health, registered tools, last start error
/mcp <server> off    # stop the client and deregister its tools for this session
/mcp <server> on     # (re)start the client and register its tools
/mcp reload          # re-read config.yml and reconnect every server (no chat restart needed)
```

`off`/`on` are session-scoped — config is untouched. `/mcp reload` is how a server added to `config.yml` mid-session becomes usable. When servers are configured, `/status` includes an `mcp` line (`2 servers · 1 reachable · 14 tools`).

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
