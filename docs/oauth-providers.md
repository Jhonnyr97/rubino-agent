# OAuth provider connectors

> **Status: NOT WIRED END-TO-END (WIP).** The pieces below exist and the HTTP
> surface works — the `/v1/oauth/...` API endpoints perform the PKCE flow and
> store **encrypted** tokens in the `oauth_connections` table. But the subsystem
> is **API-only and not yet consumed**:
> - **No tool uses the stored tokens.** Nothing reads `ConnectionRepository`
>   outside the API operations — there is no `GithubTool`/`GoogleTool` etc. that
>   pulls a connection's token to call a provider, so a connected account is not
>   actually actionable by the agent yet.
> - **No CLI surface.** There is no `rubino oauth` command; the connect/callback
>   flow needs a browser redirect, so it lives only on the API. The CLI treats
>   `RUBINO_ENCRYPTION_KEY` as optional (`doctor`: "only needed for the
>   API/OAuth server").
> - **Token sharing, when consumption lands:** tokens are not "passed" between
>   CLI and API — both read the **same SQLite DB** (same `RUBINO_HOME`) and
>   decrypt with the **same `RUBINO_ENCRYPTION_KEY`**. So wiring CLI consumption
>   = read `ConnectionRepository` + require the key on the CLI too.
>
> Open design question (issue #590): finish the native subsystem, or deprecate
> it and delegate third-party connections to an MCP server (which does its own
> OAuth and holds its own tokens). Don't depend on native OAuth in production yet.

Built-in OAuth integration lets users connect third-party accounts (Github, Google, etc.) so tools running inside rubino can act on their behalf.

## Design

Four pieces:

1. **`Rubino::OAuth::Provider`** — abstract class. Subclasses describe one provider: authorize URL builder (PKCE S256), token exchange, default scopes, account info fetcher.
2. **`Rubino::OAuth::Registry`** — Mutex-protected module. `load_from_config!` registers a provider instance per entry in `config.oauth.providers` at boot; lookup by id via `OAuth::Registry.fetch(id)`.
3. **`Rubino::OAuth::ConnectionRepository`** — Sequel-backed CRUD on `oauth_connections`. Encrypts `access_token`/`refresh_token` on write and decrypts on read. Upsert keyed on `(provider, account_id)`.
4. **`Rubino::OAuth::TokenEncryptor`** — AES-256-GCM with key from `RUBINO_ENCRYPTION_KEY` (32-byte base64). Wire format: `Base64(IV || ciphertext || tag)`.

Tools resolve tokens via the repository:
```ruby
repo = Rubino::OAuth::ConnectionRepository.new
conn = repo.list.find { |c| c[:provider] == "github" }
client = Octokit::Client.new(access_token: conn[:access_token])
```

> **Current scope:** no auto-refresh. Expired tokens are returned as-is; the tool that uses them is responsible for handling 401s (typically by surfacing a re-auth prompt). A future task will add transparent refresh inside the repository's read path.

## Built-in providers

| ID | Class | Default scopes | Grant | Required env |
|---|---|---|---|---|
| `github` | `OAuth::Provider::Github` | `repo`, `user:email` | browser PKCE **or** device code | `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET` |
| `google` | `OAuth::Provider::Google` | `openid`, `email`, `profile` | browser PKCE | `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` |
| `minimax` | `OAuth::Provider::Minimax` | `group_id`, `profile`, `model.completion` | device code (custom `user_code` grant) — CLI-login-only | `MINIMAX_OAUTH_CLIENT_ID`, `MINIMAX_OAUTH_CLIENT_SECRET` |

The three are registered in `Rubino::OAuth::Registry::BUILTINS = { github:, google:, minimax: }`.

`self.browser_flow?` (on `Provider`, default `true`) distinguishes them: `Github` and `Google` support the browser authorization-code + PKCE redirect; `Minimax` overrides it to `false`, so it is only reachable through the device-code flow. `Github` **also** includes the `DeviceCodeFlow` mixin, so it accepts either grant (`rubino auth login github --device` forces the device path).

Adding a new provider = new file under `lib/rubino/oauth/provider/`, add it to `Rubino::OAuth::Registry::BUILTINS`, declare it in `config.oauth.providers`. `load_from_config!` (called at boot) instantiates and registers every BUILTIN provider whose section in the config carries both `client_id` and `client_secret`. ~50 LOC for a standard OAuth 2.0 provider.

## Flow (PKCE by default)

```
client                    rubino                provider
  │                            │                         │
  │  POST /v1/oauth/.../connect │                         │
  │ ───────────────────────────►│                         │
  │                            │  generates state +      │
  │                            │  PKCE code_verifier     │
  │  { authorize_url, state,    │                         │
  │    code_verifier }          │                         │
  │ ◄───────────────────────────│                         │
  │                            │                         │
  │   user redirected to authorize_url                    │
  │ ─────────────────────────────────────────────────────►│
  │                            │                         │
  │   provider redirects to client with code + state      │
  │ ◄─────────────────────────────────────────────────────│
  │                            │                         │
  │  POST /v1/oauth/.../callback│                         │
  │  { code, state, expected_state,                       │
  │    code_verifier, redirect_uri }                      │
  │ ───────────────────────────►│                         │
  │                            │  POST /token            │
  │                            │ ───────────────────────►│
  │                            │ ◄───────────────────────│
  │  serialized connection      │                         │
  │  (id, provider, account_id, │                         │
  │   account_email, scopes,    │                         │
  │   expires_at, metadata)     │                         │
  │ ◄───────────────────────────│                         │
```

The **client** (e.g. a web UI) keeps `state` + `code_verifier` between connect and callback. rubino does not maintain a per-flow session — keeps it stateless.

## Flow (device code — RFC 8628)

For providers whose `self.browser_flow?` is `false` (MiniMax), or when the browser path is force-disabled (`rubino auth login github --device`), there is no redirect and no loopback server. The `Rubino::OAuth::DeviceCodeFlow` mixin drives it: a Provider includes the mixin and defines `device_authorization_endpoint` (and, when they differ from the defaults, `device_token_endpoint` / `device_grant_type`).

```
client / CLI                rubino                  provider
  │                            │                         │
  │  build_device_code_request │                         │
  │ ───────────────────────────►│  POST device_authz     │
  │                            │ ───────────────────────►│
  │  { user_code,              │ ◄───────────────────────│
  │    verification_uri,        │                         │
  │    expires_in, interval }   │                         │
  │ ◄───────────────────────────│                         │
  │                            │                         │
  │  user opens verification_uri and enters user_code     │
  │ ─────────────────────────────────────────────────────►│
  │                            │                         │
  │  poll_device_code (every `interval`s until expiry)    │
  │ ───────────────────────────►│  POST device_token      │
  │                            │ ───────────────────────►│
  │       :pending / :slow_down / :expired / token hash   │
  │ ◄───────────────────────────│ ◄───────────────────────│
```

`poll_device_code` returns `:pending`, `:slow_down`, or `:expired` on the RFC 8628 error codes and a normalized token hash on success; the CLI (`AuthCommand#device_code_login`) loops on `interval`, backing off on `:slow_down`, until it gets a hash or hits the deadline.

- **GitHub** uses the standard RFC 8628 shape: `device_code` grant, standard error codes, `stateless_device_flow? == true` (so the stateless HTTP API device endpoints can serve it).
- **MiniMax** uses a *custom* grant `urn:ietf:params:oauth:grant-type:user_code` and overrides both `build_device_code_request` and `poll_device_code`: PKCE is on the initial `/oauth/code` request (challenge on request, verifier on poll — the reverse of RFC 7636), and the poll response carries a JSON `status` discriminator (`pending` / `error` / `success`) rather than RFC 8628 error codes. Because the PKCE `code_verifier` is held in-memory across the connect+poll loop, `stateless_device_flow?` is `false` — the stateless HTTP API device endpoints reject MiniMax, so it is **CLI-login-only** (`rubino auth login minimax`).

## Storage

```sql
CREATE TABLE oauth_connections (
  id              text PRIMARY KEY,      -- uuid
  provider        text NOT NULL,
  account_id      text NOT NULL,         -- provider's user id
  account_email   text,
  access_token    text NOT NULL,         -- encrypted, Base64(IV||ct||tag)
  refresh_token   text,                  -- encrypted, Base64(IV||ct||tag)
  expires_at      text,                  -- iso8601
  scopes_json     text NOT NULL,         -- json array
  metadata_json   text,                  -- json
  created_at      text NOT NULL,
  updated_at      text NOT NULL,
  UNIQUE (provider, account_id)
);
```

The repository transparently encodes/decodes `scopes_json`/`metadata_json` so callers see `:scopes` (Array) and `:metadata` (Hash) on read.

Encryption key from `RUBINO_ENCRYPTION_KEY` (32-byte base64). `rubino server` validates it at startup and refuses to boot (exit 1) if it's missing or malformed — there's no dev/production distinction in that check. The rest of the CLI (`chat`, `doctor`, ...) treats it as optional, since only the API/OAuth server needs it.

**Tokens are never logged. Ever.** The logger has a redaction filter on `access_token`, `refresh_token`, `client_secret`.

## Configuration

`~/.rubino/config.yml` (the same single global config file every other rubino subsystem reads — see [configuration.md](configuration.md)):
```yaml
oauth:
  providers:
    github:
      client_id: ${GITHUB_OAUTH_CLIENT_ID}
      client_secret: ${GITHUB_OAUTH_CLIENT_SECRET}
      scopes: [repo, user:email]
    google:
      client_id: ${GOOGLE_OAUTH_CLIENT_ID}
      client_secret: ${GOOGLE_OAUTH_CLIENT_SECRET}
      scopes:
        - openid
        - email
        - profile
        - https://www.googleapis.com/auth/calendar.readonly
    minimax:
      client_id: ${MINIMAX_OAUTH_CLIENT_ID}
      client_secret: ${MINIMAX_OAUTH_CLIENT_SECRET}
      scopes: [group_id, profile, model.completion]
```

`load_from_config!` only registers a BUILTIN section carrying both `client_id` and `client_secret`, so every provider — MiniMax included — needs both keys present to become connectable, even though MiniMax authenticates via the device-code (not redirect) flow.

Providers not declared in config are not registered — `GET /v1/oauth/providers` only lists configured ones.

## Setup guides

### Github

1. Github → Settings → Developer settings → OAuth Apps → New
2. Authorization callback URL: `<your-client>/oauth/callback`
3. Copy Client ID + generate Client Secret
4. Export `GITHUB_OAUTH_CLIENT_ID` / `GITHUB_OAUTH_CLIENT_SECRET`

### Google

1. Google Cloud Console → APIs & Services → Credentials → Create OAuth client ID
2. Application type: Web. Authorized redirect URIs: `<your-client>/oauth/callback`
3. Enable required APIs (Calendar, Gmail, Drive, ...) based on scopes you want
4. Export `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET`

### MiniMax (device code)

MiniMax has no browser redirect flow (`browser_flow? == false`) — you authenticate from the terminal:

1. Declare the `minimax` section under `oauth.providers` with `client_id` + `client_secret` (both required for it to register)
2. Export `MINIMAX_OAUTH_CLIENT_ID` / `MINIMAX_OAUTH_CLIENT_SECRET`
3. Run `rubino auth login minimax` — the CLI prints a `verification_uri` + `user_code`, then polls until you authorize (the device-code path is auto-selected because MiniMax is not a browser-flow provider)

MiniMax uses a custom `user_code` grant with PKCE and cannot be authenticated through the HTTP API device endpoints (`stateless_device_flow? == false`) — it is CLI-login-only. This is the OAuth connector flow, and is separate from configuring MiniMax as your chat model via a plain `MINIMAX_API_KEY` (see [models-and-keys.md](models-and-keys.md)).

## Why we did this (and not "delegate to client")

Rich did it: it has `/api/providers/oauth/*`. Reason it makes sense in rubino too:

- **Tools need tokens.** A `GithubTool` needs a token to call the API. If OAuth is the client's responsibility, the client has to forward tokens with every run, which is ugly and leaky.
- **Refresh logic will be centralized.** Once auto-refresh lands, expired tokens get refreshed in one place, not duplicated per client.
- **Encrypted persistence.** Clients shouldn't store user tokens long-term; the agent does, encrypted, with a redaction-aware logger.

The client (a web UI) handles only the redirect dance — opening the authorize URL in a browser and POSTing the code back. Everything else stays here.

## Non-goals

- **Apple Sign-In:** uses JWT-signed assertions, not standard OAuth. Postponed.
- **Multi-account per provider:** one connection per provider per instance is supported. Multi-account requires UI for selection — out of scope.
- **OAuth1.0:** Twitter/X is the only relevant one. Postponed.
- **OIDC discovery:** providers are explicit classes. No `.well-known/openid-configuration` autodiscovery.
