# Models & keys

Which provider, which model, which key — answered in 60 seconds. The fastest path is `rubino setup`, which writes all of the blocks below for you. This page is the manual reference and the per-provider copy-paste.

## The decision

| Provider | When | Default model the wizard writes |
|---|---|---|
| **OpenAI** | Recommended default; GPT models | `gpt-4.1` |
| **MiniMax** | Anthropic-compatible | `MiniMax-M3` |
| **Anthropic** | Claude models | `claude-sonnet-4-5` |
| **Google (Gemini)** | Gemini models | `gemini-2.5-pro` |
| **OpenAI-compatible gateway** | A gateway picks the upstream | `auto` |
| **fake** | Tests/demos only | `fake/happy-path` (needs `RUBINO_ALLOW_FAKE=1`) |

How resolution works: an explicit `model.provider` (anything other than `auto`) wins. When `provider: auto`, the provider is derived from the `model.default` id by **rubino's own** `LLM::ProviderResolver` (via `LLM::CredentialCheck.resolved_provider`) — a table of id-prefix patterns (`openai|gpt|o1…` → `openai`, `anthropic|claude` → `anthropic`, `google|gemini` → `google`, `minimax|abab` → `minimax`, …). ruby_llm's model registry is **not** consulted for provider resolution; it is used only to enumerate model ids for `/model` completion (`LLM::ModelCatalog`). A key for the resolved provider must be available either via `providers.<name>.api_key` in `config.yml` **or** the provider's native ENV var.

## The default model + the missing-key preflight (refs #93)

The shipped default is:

```yaml
model:
  default: "openai/gpt-4.1"
  provider: "auto"
```

Under `provider: auto`, `ProviderResolver` matches the id prefix `openai/…` against `/\A(openai|gpt|o1|o3|o4)/` → the provider resolves to **`openai`** (OpenAI's own API), reading `OPENAI_API_KEY`. There is no OpenRouter hop — resolution is rubino's pattern table, not ruby_llm's registry.

Historically the risk here was silent failure: a brand-new user with no key would hit ~80 seconds of silent retries, then get an empty answer and a success exit — a dead end with no signal.

**This is now fixed.** Before any model call, rubino checks that the resolved provider has a usable credential (`LLM::CredentialCheck`). If not:

- On a TTY → the onboarding wizard runs so you pick a provider + paste a key.
- Non-interactively (`-q` / piped / no TTY) → it prints a clear, actionable message and exits non-zero (no silent retry storm):

  ```
  No API key configured for provider 'openai' (model openai/gpt-4.1).
  Set it up one of these ways:
    • run `rubino setup` for a guided first-run setup (creates the files below), or
    • add OPENAI_API_KEY=<your-key> to ~/.rubino/.env (or run `rubino setup` to create them), or
    • set providers.openai.api_key in ~/.rubino/config.yml (or run `rubino setup` to create them).
  ```

The simplest fix is `rubino setup`. A bare `gpt-4.1` with `provider: openai` (shown below) resolves identically — both route to OpenAI's own API.

## Where keys live

- Keys go in `~/.rubino/.env` (mode `0600`) as `KEY=value`, or directly as `providers.<name>.api_key` in `config.yml`.
- In `config.yml` you can reference an env var with the substitution syntax: `api_key: "${MINIMAX_API_KEY}"` or `"{env:MINIMAX_API_KEY}"`.
- `RUBINO_HOME` relocates the whole home (config, `.env`, and the database follow it).

The native ENV var per provider: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY` (or `GOOGLE_API_KEY`), `BEDROCK_API_KEY`, `MINIMAX_API_KEY`.

### Anthropic: OAuth bearer tokens & borrowed-token precedence

For the `anthropic` provider, beyond the static `ANTHROPIC_API_KEY`, rubino also honors two OAuth **bearer** env vars and a borrowed on-disk token. The resolution order at call time (`RubyLLMAdapter`, hermes parity — mirrored by the `doctor`/preflight `CredentialCheck`):

1. **`ANTHROPIC_TOKEN`** — OAuth bearer; wins if set.
2. **`CLAUDE_CODE_OAUTH_TOKEN`** — OAuth bearer; used next. Both bearer env vars **outrank** a static `ANTHROPIC_API_KEY`.
3. **`ANTHROPIC_API_KEY`** — the static `x-api-key`. When you set it yourself and no bearer env var is present, it wins and rubino does **not** consult the borrowed store (the deliberate "seed gate": an explicit static key opts you out of borrowing).
4. **Borrowed Claude Code OAuth token** — read from Claude Code's own credential store (macOS Keychain, else `~/.claude/.credentials.json`) by `CredentialSources` (`AnthropicOAuth`, priority 10). Consulted only when no static `ANTHROPIC_API_KEY` is set. Its priority-10 registration means that *whenever it is consulted*, the borrowed OAuth token is preferred over other lower-priority sources — the hermes-intended "Claude Code login beats a plain key," bounded here by the seed gate above.

The net effect: a machine already logged into Claude Code needs **no** `ANTHROPIC_API_KEY` to use the `anthropic` provider — the borrowed token satisfies both `doctor`/preflight and the actual call. Any of the four counts as a usable credential.

---

## Per-provider setup

Each block goes in `~/.rubino/config.yml`; the key goes in `~/.rubino/.env`.

### MiniMax (Anthropic-compatible)

MiniMax speaks the Anthropic API, so it routes through the anthropic-compatible path.

```yaml
model:
  default: "MiniMax-M3"
  provider: "minimax"

providers:
  minimax:
    anthropic_compatible: true
    base_url: "https://api.minimax.io/anthropic"
    api_key: "${MINIMAX_API_KEY}"
```

```bash
# ~/.rubino/.env
MINIMAX_API_KEY=...
```

> MiniMax M2 ignores tool definitions and roleplays bash in markdown; use **MiniMax-M3** (the wizard default) for working tool use.

### OpenAI (GPT) (recommended default)

Uses OpenAI's own API (not OpenRouter) when `provider: openai` and the model id is a bare OpenAI id.

```yaml
model:
  default: "gpt-4.1"
  provider: "openai"
```

```bash
# ~/.rubino/.env
OPENAI_API_KEY=sk-...
```

For Azure/custom endpoints set `providers.openai.base_url`.

### Anthropic (Claude)

```yaml
model:
  default: "claude-sonnet-4-5"
  provider: "anthropic"
```

```bash
# ~/.rubino/.env
ANTHROPIC_API_KEY=sk-ant-...
```

### Google (Gemini)

The provider id is `google`.

```yaml
model:
  default: "gemini-2.5-pro"
  provider: "google"
```

```bash
# ~/.rubino/.env
GEMINI_API_KEY=...
# GOOGLE_API_KEY is also accepted
```

### OpenAI-compatible gateway

Point this at any OpenAI-compatible gateway; the gateway decides which upstream (OpenAI/MiniMax/Anthropic/…) and which model to call. Route everything to it with `provider: gateway` and `model: auto`, and set `base_url` + `api_key` for your gateway.

```yaml
model:
  default: "auto"
  provider: "gateway"
  supports_vision: null   # set true/false if the gateway hides the upstream model name

providers:
  gateway:
    openai_compatible: true
    assume_model_exists: true
    base_url: "https://your-gateway/v1"
    api_key: "${OPENAI_API_KEY}"
```

`openai_compatible` providers fall back to `OPENAI_API_KEY` when no `providers.<name>.api_key` is set.

### fake (testing only)

```yaml
model:
  default: "fake/happy-path"
```

```bash
export RUBINO_ALLOW_FAKE=1   # required; chat/server refuse to boot fake otherwise
```

See the [README](../README.md#fake-llm-provider) for scenario authoring.

---

## Auxiliary models

Compression, approval scoring, vision, and document summarization can each run on a separate (often cheaper) model. By default they reuse the primary (`provider: "main"`). See [configuration.md](configuration.md#auxiliary) — for example, set `auxiliary.vision.model: "auto-vision"` to let an OpenAI-compatible gateway pick a vision model for the `vision` tool.

## Verifying

```bash
rubino doctor
```

`doctor` reports the resolved provider for your configured model and whether a usable credential is present — the same check the chat preflight uses.
