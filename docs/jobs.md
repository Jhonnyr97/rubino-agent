# Jobs

Background work in rubino is split into two surfaces that share the `Rubino::Jobs::*` namespace but operate independently:

1. **Internal background queue** — async side-effects the agent enqueues for itself (memory extraction, context compaction, session summarization, retention sweeps).
2. **Cron jobs** — user-defined schedules that fire fresh agent runs on a cron expression, with optional webhook delivery on completion. HTTP surface lives at [`/v1/jobs`](api/v1.md#cron-jobs).

This doc describes both, plus the **Backend Adapter contract** that the queue and the scheduler are designed to be plugged into so the gem can be hosted on Sidekiq / SolidQueue / GoodJob / ActiveJob without rewriting handlers.

---

## Internal background queue

### Purpose

Defer slow or out-of-band work off the request and chat paths. Anything an agent doesn't need to block on — extracting memories from a finished turn, compacting a session that crossed the threshold, GC'ing ended sessions — goes through the queue.

### Storage (default `Sqlite` backend)

```sql
CREATE TABLE jobs (
  id           text PRIMARY KEY,        -- uuid
  type         text NOT NULL,           -- Jobs::Registry key
  status       text NOT NULL,           -- queued | running | completed | dead
  priority     integer NOT NULL,        -- lower runs first
  payload_json text NOT NULL,           -- JSON-serialised hash
  attempts     integer NOT NULL,
  max_attempts integer NOT NULL,
  run_at       text NOT NULL,           -- iso8601, "not before"
  locked_at    text,
  locked_by    text,                    -- worker_id
  last_error   text,
  created_at   text NOT NULL,
  updated_at   text NOT NULL
);

CREATE TABLE job_runs (
  id          text PRIMARY KEY,         -- uuid, one row per execution attempt
  job_id      text NOT NULL,
  status      text NOT NULL,
  started_at  text,
  finished_at text,
  error       text
);
```

### Lifecycle

```
enqueue ──► (status=queued) ──► dequeue (worker locks row)
                                       │
                                       ▼
                                  handler.perform(payload)
                                       │
                            ┌──────────┴───────────┐
                            ▼                      ▼
                    Queue#complete!          Queue#fail!(error:)
                    status=completed         attempts += 1
                                             retry_at = now + backoff·attempts
                                             status=queued (or dead at max_attempts)
```

Retry uses linear backoff: `retry_backoff_seconds * attempts`. After `max_attempts` the row stays at `status=dead` for inspection — nothing reaps it automatically.

### Execution modes

`config.jobs_mode` selects how enqueued jobs actually run:

| Mode | Behavior | When to use |
|---|---|---|
| `inline` | `Queue#enqueue` runs the handler synchronously in the same call stack. | dev, tests, smoke runs |
| `manual` | enqueue only — nothing runs until `rubino jobs run` is invoked. | air-gapped or CI batch flows |
| `worker` | a long-running `rubino jobs worker` polls and dequeues. | production single-process |

The worker is a single-threaded poll loop with `SIGINT`/`SIGTERM` graceful stop. It is not safe to run more than one worker per SQLite file — locking is row-level but `WAL` contention will dominate. Multi-process scaling is what the [Backend Adapter](#backend-adapter-planned-design) section is for.

### Handler contract

A handler is any class that responds to `#perform(payload)`. The Registry maps a type string → handler class:

```ruby
module Rubino
  module Jobs
    module Handlers
      class MyJob
        def perform(payload)
          # payload comes back as a symbol-keyed Hash
          session_id = payload[:session_id]
          # ...
        end
      end
    end
  end
end

Rubino::Jobs::Registry.register("MyJob", Rubino::Jobs::Handlers::MyJob)
```

Enqueue:

```ruby
Rubino::Jobs::Queue.new.enqueue("MyJob", session_id: "abc")
```

### Built-in handlers

| Type | Handler | Payload | Side-effect |
|---|---|---|---|
| `ExtractMemoryJob` | `Handlers::ExtractMemoryJob` | `{session_id}` | `Memory::Extractor#extract_from_session` |
| `CompactSessionJob` | `Handlers::CompactSessionJob` | `{session_id}` | `Context::Compressor#compact!` |
| `SummarizeSessionJob` | `Handlers::SummarizeSessionJob` | `{session_id}` | `Context::SummaryBuilder#build_and_save!` |
| `CleanupSessionsJob` | `Handlers::CleanupSessionsJob` | `{retention_days?}` | deletes `sessions` rows with `status="ended"` older than retention (default 30d) |

### CLI

```bash
rubino jobs list          # show recent rows from jobs table
rubino jobs run           # drain queued rows once (uses Runner#run_pending)
rubino jobs worker        # start the polling worker (long-running)
```

---

## Cron jobs

User-defined cron schedules, persisted in the `cron_jobs` table, dispatched by `Jobs::Scheduler` — a process-wide singleton wrapping `rufus-scheduler`.

Each cron tick:

1. Creates a fresh `Session` (source=`"cron"`).
2. Creates a `Run` stamped with `cron_job_id`.
3. Hands the run to `Run::Executor#start`.
4. On completion: optionally posts a payload to `RUBINO_WEBHOOK_URL` when `deliver: "webhook"`.

Configuration is HTTP-only — there is no YAML loader for cron jobs. Full request/response shapes are in [`docs/api/v1.md`](api/v1.md#cron-jobs); the routes are:

```
POST   /v1/jobs                    # create
GET    /v1/jobs                    # list
GET    /v1/jobs/:id                # show
PATCH  /v1/jobs/:id                # update
DELETE /v1/jobs/:id                # delete + unschedule
POST   /v1/jobs/:id/pause          # disable + unschedule
POST   /v1/jobs/:id/resume         # enable + reschedule
POST   /v1/jobs/:id/trigger        # fire once now
```

### Scheduler boot

`Jobs::Scheduler.instance.load_all!` is called once at server boot. It loads every `enabled: true` row from `cron_jobs` and registers a rufus cron handle for each.

```ruby
scheduler = Rubino::Jobs::Scheduler.instance
scheduler.load_all!                     # at server boot
scheduler.schedule(job_row)             # after POST /v1/jobs
scheduler.unschedule(job_id)            # after DELETE
scheduler.trigger(job_id)               # one-shot
scheduler.shutdown!                     # at server stop
```

### Webhook delivery

`Jobs::WebhookDelivery` is a thin Faraday + faraday-retry client. Best-effort: every failure path (no URL, non-2xx, transport error) is logged and counted, never raised.

| Setting | Value |
|---|---|
| URL | `RUBINO_WEBHOOK_URL` env (single URL for the whole process) |
| Timeout | 10s |
| Retry | 2 attempts, 0.5s initial interval, exponential backoff factor 2 |
| Retry triggers | `Faraday::TimeoutError`, `Faraday::ConnectionFailed` |
| Payload | `{ job_id, job_name, run_id, status, session_id }` |
| Metrics | `webhook_deliveries_total{outcome="ok"|"http_error"|"error"}` |

Per-job webhook URLs and signed payloads are planned.

### Multi-process limitation

Because rufus lives in the Ruby heap, **every Puma worker** would run **every cron tick** if you scaled `rubino server` horizontally. The scheduler currently ships as single-instance only. The [Backend Adapter](#backend-adapter-planned-design) section sketches what cluster-safe scheduling looks like.

---

## Backend Adapter (planned design)

The internal queue today is hardwired to SQLite via Sequel. For real production deployments — multi-process Puma, k8s pods, heavy fanout — the natural move is to plug Sidekiq / SolidQueue / GoodJob / Resque underneath without rewriting any handler.

The contract below is **not implemented yet**. It is documented so that:

1. Today's `Jobs::Queue` keeps a stable public method set (`enqueue / find / list / pending_count`) that can become the adapter facade later.
2. Anyone writing a new handler today knows what *not* to depend on (DB queries on `:jobs`, transaction semantics, Sequel handles).
3. When the adapter lands, the migration is a config flip, not a rewrite.

### `Jobs::Backend` contract

```ruby
module Rubino
  module Jobs
    # Single point of contact between Jobs::Queue (a thin facade once this
    # ships) and whatever runs the work in production.
    #
    # Implementations MUST be thread-safe AND process-safe. The agent
    # assumes nothing about how work is durably stored or dispatched —
    # only that the four methods below behave per their contract.
    module Backend
      # Schedule a job for execution.
      #
      # @param type     [String]  handler type (matches Jobs::Registry key)
      # @param payload  [Hash]    JSON-serialisable. No symbols on the wire,
      #                           no Time objects, no Sequel rows.
      # @param priority [Integer] lower runs first; semantics are best-effort.
      # @param run_at   [Time, nil] not-before timestamp; nil means ASAP.
      # @return [String] backend-specific job id, round-trippable via #find.
      def enqueue(type:, payload:, priority: 100, run_at: nil); end

      # Look up a single job by the id returned from #enqueue.
      # @return [Hash, nil] {id:, type:, status:, attempts:, last_error:, ...}
      def find(id); end

      # Snapshot for /v1/health and `rubino jobs list`.
      # @return [Hash] e.g. {queued: 4, running: 1, dead: 0, completed: 132}
      def stats; end

      # Drain up to `limit` queued jobs in-process. Used by `inline` mode
      # and tests. Adapters with no in-process executor (Sidekiq client-only
      # mode) MAY raise NotImplementedError.
      def drain!(limit: 100); end

      # Optional. GC for completed/dead rows. Operators call this via
      # `rubino jobs cleanup`. Implementations without a "completed"
      # state (e.g. fire-and-forget transports) may no-op.
      def purge_completed!(older_than:); end
    end
  end
end
```

Wire-up:

```ruby
Rubino.configure do |c|
  c.jobs_backend = Rubino::Jobs::Backend::Sqlite.new      # current default
  # c.jobs_backend = MyApp::SidekiqAdapter.new               # opt-in
end
```

`Jobs::Queue.new` becomes a façade that delegates to `Rubino.configuration.jobs_backend`. No handler changes; no API changes; `inline` / `manual` / `worker` modes collapse into whatever the adapter exposes.

### Sketch adapters (NOT shipped yet)

Each row below shows the **only file** an integrator would have to write. Handlers stay the same Ruby object with `#perform(payload)`.

| Adapter | Underlying lib | Transport | Retry / DLQ | Cron |
|---|---|---|---|---|
| `Backend::Sqlite` | Sequel | SQLite table polling | linear backoff, `dead` status | rufus (in-process) |
| `Backend::Sidekiq` | sidekiq | Redis | sidekiq retry + DLQ | sidekiq-cron |
| `Backend::SolidQueue` | solid_queue | ActiveRecord (no Redis) | SolidQueue retry | SolidQueue recurring jobs |
| `Backend::GoodJob` | good_job | Postgres LISTEN/NOTIFY | GoodJob retry | GoodJob cron |
| `Backend::ActiveJob` | activejob | host app's queue_adapter | adapter-dependent | adapter-dependent |

Indicative shape (informational only):

```ruby
# This file would live in the host application — NOT in the gem.
class MyApp::Jobs::SidekiqAdapter
  def enqueue(type:, payload:, priority: 100, run_at: nil)
    handler = Rubino::Jobs::Registry.handler_for(type) or raise "unknown type: #{type}"
    # Wrap the handler once so Sidekiq has a class with `perform`.
    job_class = MyApp::Jobs::RubinoSidekiqWrapper
    args = [type, JSON.generate(payload)]
    if run_at
      job_class.perform_at(run_at, *args)
    else
      job_class.perform_async(*args)
    end
  end
  # find/stats/drain!/purge_completed! similarly
end
```

The wrapper class on the Sidekiq side just dispatches:

```ruby
class MyApp::Jobs::RubinoSidekiqWrapper
  include Sidekiq::Job
  def perform(type, payload_json)
    payload = JSON.parse(payload_json, symbolize_names: true)
    Rubino::Jobs::Registry.handler_for(type).new.perform(payload)
  end
end
```

### Cron scheduler adapter (parallel design)

Cron has the same shape. Today rufus is a singleton wrapping in-process callbacks; tomorrow a `Scheduler::Backend` decides whether the tick happens here or somewhere else.

```ruby
module Rubino::Jobs::Scheduler::Backend
  def schedule(job);   end   # job row from cron_jobs
  def unschedule(id);  end
  def trigger(id);     end   # one-shot now
  def load_all!;       end   # boot
  def shutdown!;       end
end
```

| Adapter | What ticks the cron |
|---|---|
| `Scheduler::Backend::Rufus` | rufus-scheduler in-process (current) |
| `Scheduler::Backend::SidekiqCron` | sidekiq-cron / sidekiq-scheduler |
| `Scheduler::Backend::SolidCron` | SolidQueue recurring jobs table |
| `Scheduler::Backend::Kubernetes` | host cluster's `CronJob` POSTs `/v1/jobs/:id/trigger` on schedule; rubino never schedules anything itself |

In every case the HTTP surface (`/v1/jobs`) does not change. Only **who actually fires the tick** changes.

---

## Non-goals

- **Pluggable backends are designed, not shipped.** The default and only backend is `Sqlite`. The `Jobs::Backend` module above does not exist in the code yet — `Jobs::Queue` is the SQLite implementation directly.
- **No cluster-safe cron.** The rufus scheduler is single-instance only. Running more than one `rubino server` in front of the same DB will multi-fire every cron job.
- **No per-job webhook URLs**, no payload signing, no signed JWT-style retry tokens. One URL per process via `RUBINO_WEBHOOK_URL`.
- **No queue web UI.** `rubino jobs list` and `/v1/jobs` are the only inspection surfaces.
- **No fan-out, no per-tenant queues, no priority classes.** Priority is a single integer column, best-effort.
- **No automatic dead-row GC.** Failed-past-max-attempts rows stay at `status=dead` until an operator removes them.

## Why a contract, not just a config flag

The handler classes are the API. As long as `perform(payload)` is stable and idempotent, swapping the backend is a deploy concern, not a rewrite. Documenting the contract now (and keeping `Jobs::Queue`'s public method surface aligned with `Backend`) is what keeps "let's move to Sidekiq" a one-day task instead of a one-month refactor.
