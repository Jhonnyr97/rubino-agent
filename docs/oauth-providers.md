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

| ID | Class | Default scopes | Required env |
|---|---|---|---|
| `github` | `OAuth::Provider::Github` | `repo`, `user:email` | `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET` |
| `google` | `OAuth::Provider::Google` | `openid`, `email`, `profile` | `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` |

Adding a new provider = new file under `lib/rubino/oauth/provider/`, add it to `Rubino::OAuth::Registry::BUILTINS`, declare it in `config.oauth.providers`. `load_from_config!` (called at boot) instantiates and registers every provider whose section in the config carries both `client_id` and `client_secret`. ~50 LOC for a standard OAuth 2.0 provider.

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

Encryption key from `RUBINO_ENCRYPTION_KEY` (32-byte base64). Boot fails if missing in production.

**Tokens are never logged. Ever.** The logger has a redaction filter on `access_token`, `refresh_token`, `client_secret`.

## Configuration

`config/rubino.yml`:
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
```

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
