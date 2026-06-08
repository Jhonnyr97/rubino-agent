# MCP Integration

> **Status: PLANNED.** MCP integration is designed in (via [ruby_llm-mcp](https://github.com/patvice/ruby_llm-mcp)) but not fully wired yet — don't depend on it in production.

rubino supports the [Model Context Protocol](https://modelcontextprotocol.io/) via [ruby_llm-mcp](https://github.com/patvice/ruby_llm-mcp).

## Configuration

Add MCP servers in `config.yml`:

```yaml
mcp:
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

    # Remote server via streamable HTTP (with OAuth)
    oauth_server:
      transport: streamable
      url: "https://mcp.example.com/api"
      oauth:
        client_id: "{env:MCP_CLIENT_ID}"
        client_secret: "{env:MCP_CLIENT_SECRET}"
        scope: "mcp:read mcp:write"
      timeout: 15000
```

## Transport Types

| Transport | Use Case | Config |
|-----------|----------|--------|
| `stdio` | Local MCP servers, CLI tools | `command`, `args`, `env` |
| `sse` | Web-based servers with Server-Sent Events | `url`, `headers` |
| `streamable` | HTTP servers with streaming support | `url`, `headers`, `oauth` |

## How It Works

1. On startup, `MCP::Manager` connects to all configured servers
2. Each server's tools are wrapped in `MCPToolWrapper` (adapts to `Tools::Base` interface)
3. Wrapped tools are registered in `Tools::Registry` with a prefix (`servername_toolname`)
4. The agent can use MCP tools like any built-in tool

## Per-Agent Scoping

Control which MCP servers each agent can access:

```yaml
agents:
  explore:
    mcp_servers: ["filesystem"]   # Only filesystem MCP
  build:
    mcp_servers: all              # All MCP servers (default)
  plan:
    mcp_servers: []               # No MCP tools
```

In code:

```ruby
Rubino::Agent::Definition.new(
  name: "secure_agent",
  mcp_servers: ["internal_api"]  # Only this server's tools
)
```

## OAuth Authentication

For remote MCP servers requiring OAuth:

```yaml
mcp:
  servers:
    protected:
      transport: streamable
      url: "https://mcp.corp.example.com/api"
      oauth:
        client_id: "{env:MCP_OAUTH_CLIENT_ID}"
        client_secret: "{env:MCP_OAUTH_CLIENT_SECRET}"
        scope: "mcp:read mcp:write"
```

The OAuth flow uses PKCE and opens a browser for authentication. Tokens are stored in `~/.rubino/oauth_tokens.json` (permissions: 600).

## Manual Management

```ruby
# Start all servers
manager = Rubino::MCP::Manager.new
manager.start_all!

# Get tools for a specific agent
tools = manager.tools_for_agent(agent_definition)

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
rubino doctor   # Shows MCP server status in health check
rubino tools    # Lists all tools including MCP tools
```
