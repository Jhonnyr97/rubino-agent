# Observability (OpenTelemetry)

Rubino can export distributed traces of every turn over [OpenTelemetry](https://opentelemetry.io) (OTLP http/protobuf), following the [OTel GenAI semantic conventions](https://github.com/open-telemetry/semantic-conventions-genai). It is **off by default**, adds **zero overhead when off**, and **never exports message text unless you explicitly opt in**.

## Quick start

1. Install the optional gems (they are not bundled — a default install carries no OTel weight):

   ```sh
   gem install opentelemetry-sdk opentelemetry-exporter-otlp
   ```

2. Enable it in `~/.rubino/config.yml`:

   ```yaml
   otel:
     enabled: true
     endpoint: "http://localhost:4318"   # your OTLP collector (base URL is fine)
   ```

3. Point it at any OTLP-compatible backend. For a local look, Jaeger all-in-one works out of the box:

   ```sh
   docker run --rm -p 16686:16686 -p 4318:4318 jaegertracing/all-in-one
   rubino "list the files in this directory"
   # open http://localhost:16686 → service "rubino-agent"
   ```

Leaving `endpoint` unset falls back to the standard `OTEL_EXPORTER_OTLP_*` environment variables, then the SDK default (`http://localhost:4318`). Spans are batched and flushed on process exit.

## What gets traced

One trace per turn, shaped like the turn itself:

```
invoke_agent rubino                        the whole turn (Interaction::Lifecycle)
├── chat claude-sonnet-4-5                 one span per model call, retries/fallbacks included
├── execute_tool shell                     one span per tool call, approval gate included
├── execute_tool task
│   └── invoke_agent researcher            a foreground subagent turn nests under its `task` call
│       ├── chat claude-sonnet-4-5
│       └── execute_tool read
└── chat claude-sonnet-4-5
```

| Span | Where | Always-on attributes |
|---|---|---|
| `invoke_agent <agent>` | one per turn | `gen_ai.operation.name`, `gen_ai.agent.name`, `gen_ai.conversation.id` (session id), `rubino.turn.stop_reason` |
| `chat <model>` | one per model call (the whole retry/recovery/fallback envelope) | `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.response.finish_reasons`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.usage.cache_read.input_tokens`, `gen_ai.usage.cache_creation.input_tokens`, `rubino.iteration` |
| `execute_tool <name>` | one per tool call (MCP tools included — their registry name is `<server>_<tool>`) | `gen_ai.tool.name`, `gen_ai.tool.call.id`, `rubino.tool.status` (`success` / `error` / `denied`), `rubino.tool.decision.source` (which mechanism decided: `auto` / `user` / `policy` / `hardline` / `permissions: deny` / `doom-loop` / `no interactive session`), `rubino.tool.target` (the skill / subagent name for `skill` and `task` calls) |
| `chat <model>` + `rubino.aux.task` | one per auxiliary LLM call (summarize / title / vision / approval / compression) | same as `chat`, plus `rubino.aux.task` to tell aux spend apart from the main loop |
| `search_memory` | the turn-opening memory recall | `gen_ai.operation.name`, `rubino.memory.relevant_count` |

Notes:

- **Errors**: an exception unwinding through a span is recorded on it with error status (standard OTel), so a failed turn is visible in the trace without any extra wiring.
- **Cache health**: `gen_ai.usage.cache_read.input_tokens` on every `chat` span makes prompt-cache regressions (a busted KV prefix) directly visible as a per-call time series.
- **Denied tools still produce spans** (`rubino.tool.status: denied`) — an approval denial is an observable outcome, not a gap in the trace.
- **Background subagents** run on their own threads and start their own traces (OTel context is thread-local). Foreground delegation nests, as shown above.
- **Memory and skills**: the model-driven `memory` / `skill` tool calls appear as ordinary `execute_tool` spans; the turn-opening recall has its own `search_memory` span; and the post-turn background review (the fork that extracts memories and captures skills) runs through the normal Runner/Lifecycle, so it shows up as its own `invoke_agent` trace with its `chat` and `execute_tool memory`/`execute_tool skill` children.

## Audit model: traces find, transcripts explain

The always-on trace is the **decision skeleton**: which tools ran, in what order, what was denied and by which mechanism (`rubino.tool.decision.source`), which skill/subagent was involved, what it cost. The full *content* answering "why did the agent do that?" lives in the session transcript rubino already persists (SQLite session store) — and every trace carries `gen_ai.conversation.id`, the session id, so an audit goes: find the span in Grafana → open that session's transcript at that turn. Keep the transcript store's retention longer than the traces' (`cleanup.period_days`) — it is the audit log.

## Privacy model

By default the exported data is *shape only*: names, ids, models, token counts, durations, statuses. No prompt text, no tool arguments, no outputs.

To include content (useful in a private dev setup, with a collector you own), opt in with either:

```yaml
otel:
  capture_content: true
```

or the standard GenAI-semconv environment variable:

```sh
OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true
```

Even then, payloads pass the same redactor as rubino's structured logs (`Rubino::Logger.redact` — API keys, tokens, and other secret-shaped fields become `[REDACTED]`) and are truncated to 16k characters per attribute. Content rides as `gen_ai.input.messages` / `gen_ai.output.messages` on `chat` spans and `gen_ai.tool.call.arguments` / `gen_ai.tool.call.result` on `execute_tool` spans.

## Failure behavior

Telemetry is fail-open and can never take down a turn:

- `otel.enabled: true` without the gems installed logs one `telemetry.gems_missing` warning (with the install command) and disables itself.
- A broken exporter config logs `telemetry.boot_failed` and disables itself.
- An unreachable collector is the exporter's problem (batched, retried, eventually dropped) — the agent never blocks on it.

## Config reference

See [configuration.md](configuration.md#otel) for the full `otel:` block. Config is read once at first use — changing it requires a restart.
