# Troubleshooting

Keyed on the exact strings you'll see. Run `rubino doctor` first — it reports config, the resolved provider, credential presence, and database health.

## `No API key configured for provider '...' (model ...)`

The resolved provider has no usable credential, so the run failed fast (instead of the old ~80s silent-retry-then-empty dead end, #93).

Fix one of:

- `rubino setup` — guided first-run; pick a provider and paste a key.
- add `<PROVIDER>_API_KEY=<key>` to `~/.rubino/.env`.
- set `providers.<provider>.api_key` in `~/.rubino/config.yml`.

See [models-and-keys.md](models-and-keys.md).

## First message hung ~80s then exited empty (older versions)

The historical default→OpenRouter trap: the shipped `model.default` `openai/gpt-4.1` resolves to **OpenRouter** in ruby_llm's registry, and a missing key produced a silent retry storm and an empty success. Current versions fail fast with the message above (interactively, they launch the onboarding wizard). If you still see a hang, you're on an old build — upgrade, or run `rubino setup`.

## OpenRouter is mentioned but I never chose it

Same root cause: `openai/gpt-4.1` is an OpenRouter-namespaced id. To use OpenAI's own API, set a bare model id with an explicit provider:

```yaml
model:
  default: "gpt-4.1"
  provider: "openai"
```

Or run `rubino setup` and pick a provider explicitly. See [models-and-keys.md](models-and-keys.md#the-defaultopenrouter-trap-refs-93).

## `rubino isn't set up yet — run \`rubino setup\` first.`

The database couldn't be auto-initialized. `chat` auto-creates the home dirs and runs migrations on boot, so this only appears when that itself fails (e.g. unwritable home). Check that `~/.rubino` (or `$RUBINO_HOME`) is writable, then run `rubino setup`.

## `fake provider is dev-only — set RUBINO_ALLOW_FAKE=1 to opt in.`

Your configured `model.provider` is `fake`. The fake provider can short-circuit tool decisions and is blocked in `chat`/`server` unless you set `RUBINO_ALLOW_FAKE=1`. Either set that env var (dev only) or switch to a real provider.

## `rubino memory list` says no memories but the agent clearly remembers things

Fixed in #94. The CLI now reads the **active** backend (`memory.backend`, default `sqlite`) — the same store the agent writes to. If you're on an old build, the CLI read a hardwired legacy table. Confirm the active backend with `rubino memory backend`, and upgrade if it still mismatches.

## Memory recall misses an obvious fact

The sqlite backend ranks by direct content relevance (FTS5/BM25) first; graph/recency only backfill. If a fact isn't surfacing, check it's still **live** (`rubino memory list` shows live facts; superseded ones are hidden) and that your probe shares non-stopword terms with the fact. Vector KNN is off by default — enable `memory.sqlite.vector: true` (needs `RubyLLM.embed`) for semantic matches. See [memory.md](memory.md).

## The agent keeps asking to approve every shell command

That's `security.require_confirmation_for_shell: true` (the default `confirm_all` policy). Options: approve for the session at the prompt, add prefixes to `security.command_allowlist`, switch to `dangerous_only` (`security.confirm_policy: dangerous_only`), or use `/mode yolo` / `--yolo` to skip prompts (the hardline floor and `permissions: deny` still apply). See [security.md](security.md).

## A command was denied even with `--yolo`

The hardline floor and explicit `permissions: deny` rules run **before** the yolo allow-exit by design — yolo trusts the agent to move fast, not to wipe the disk. See the [hardline floor](security.md#the-hardline-floor) for the (tiny) blocked set.

## Connection refused / unauthorized against the API

- **Connection refused** — the server binds `127.0.0.1` by default. Use `--host 0.0.0.0` (or `RUBINO_API_HOST`) to expose it, only behind TLS or a trusted segment.
- **401 unauthorized** — every route except `GET /v1/health` and `GET /v1/metrics` requires `Authorization: Bearer <RUBINO_API_KEY>`. Set `RUBINO_API_KEY` (or `--api_key`) on the server and send the matching token.
- **TLS errors on the web→agent hop** — the API serves a self-signed cert; the client must **pin** it. Fetch it with `rubino tls-cert`. See [security.md](security.md#tls-for-the-http-api).

## OAuth routes return errors

OAuth token storage needs `RUBINO_ENCRYPTION_KEY` set (e.g. `openssl rand -base64 32`). See [oauth-providers.md](oauth-providers.md).

## Tool shows as disabled in `rubino tools`

Tools are opt-out: a `tools.<key>: false` in config disables them. Note both web tools share `tools.web`. `plan` mode also hides mutating tools. Check your config and current mode (`/status`).

## Network calls fail behind a corporate proxy

Set the standard `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` variables (SOCKS supported). There is **no** `RUBINO_PROXY_URL`. For a custom CA bundle, set `SSL_CERT_FILE`.
