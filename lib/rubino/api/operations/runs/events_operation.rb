# frozen_string_literal: true

require "json"

module Rubino
  module API
    module Operations
      module Runs
        # GET /v1/runs/:id/events — Server-Sent Events stream.
        #
        # Replays persisted events (honoring the `Last-Event-ID` header for
        # resume), then polls for new ones at POLL_INTERVAL until the run
        # reaches a terminal status (completed/failed/stopped) or disappears.
        # Puma handles the chunked transfer transparently.
        #
        # @return [[Integer, Hash, Enumerable]] 200 + SSE headers + lazy streamer.
        # @raise [Rubino::NotFoundError] when the run does not exist.
        class EventsOperation
          TERMINAL_STATUSES = %w[completed failed stopped].freeze
          POLL_INTERVAL = 0.25
          # Proxies (nginx, caddy, ALB) close idle connections around 30–60s;
          # 15s leaves margin and also exercises the write path so we notice
          # client disconnects (EPIPE/ECONNRESET) without waiting for a real event.
          HEARTBEAT_INTERVAL = 15.0
          HEARTBEAT_FRAME = ": heartbeat\n\n"
          # Watchdog: if the run is still "running" but no new event has been
          # written for this many seconds, give up and mark it failed. Covers
          # cases the Executor's rescue can't (model in an infinite tool loop,
          # provider stream silently stalled, OS thread killed by a signal we
          # never saw). Generous enough to outlast a slow tool call but well
          # under the SSE consumer's job timeout. Tunable via config so an op can dial
          # it down for short tasks or up for legit long-running computations.
          DEFAULT_IDLE_EVENT_TIMEOUT = 300.0
          # Writes to a closed/aborted socket surface as one of these; we treat
          # them all as "client gone" and stop polling so the thread doesn't
          # leak until the run reaches a terminal status.
          DISCONNECT_ERRORS = [Errno::EPIPE, Errno::ECONNRESET, IOError].freeze

          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate run repository and event store for tests.
          # `clock` and `sleeper` are seams so heartbeat/disconnect specs can
          # drive virtual time without sleeping in real wall-clock seconds.
          # `idle_event_timeout` overrides the watchdog window (defaults from
          # config so ops can dial without code changes; nil disables it).
          def initialize(repository: nil, event_store: nil, clock: nil, sleeper: nil, idle_event_timeout: :default)
            @repository = repository || ::Rubino::Run::Repository.new
            @store = event_store || ::Rubino::Run::EventStore.new
            @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            @sleeper = sleeper || ->(seconds) { sleep(seconds) }
            @idle_event_timeout = idle_event_timeout == :default ? configured_idle_timeout : idle_event_timeout
          end

          def call(request)
            id = request.params.fetch("id")
            run = @repository.find(id)
            raise NotFoundError.new("run", id) unless run

            after_seq = parse_last_event_id(request.header("Last-Event-ID"))
            headers = {
              "content-type" => "text/event-stream",
              "cache-control" => "no-cache",
              "x-accel-buffering" => "no"
            }
            [200, headers, build_stream(id, after_seq)]
          end

          private

          def parse_last_event_id(header_value)
            return nil if header_value.nil? || header_value.empty?

            Integer(header_value, 10)
          rescue ArgumentError
            nil
          end

          def build_stream(run_id, after_seq)
            store = @store
            repo = @repository
            clock = @clock
            sleeper = @sleeper
            idle_timeout = @idle_event_timeout
            Enumerator.new do |y|
              cursor = after_seq
              now = clock.call
              last_write_at = now
              last_real_event_at = now
              begin
                # Replay persisted events first.
                store.for_run(run_id, after_seq: cursor).each do |event|
                  cursor = event[:seq]
                  y << format_event(event)
                  last_write_at = clock.call
                  last_real_event_at = last_write_at
                end
                # Then poll for new events until terminal.
                loop do
                  fresh = store.for_run(run_id, after_seq: cursor)
                  fresh.each do |event|
                    cursor = event[:seq]
                    y << format_event(event)
                    last_write_at = clock.call
                    last_real_event_at = last_write_at
                  end
                  run = repo.find(run_id)
                  break if run.nil? || TERMINAL_STATUSES.include?(run[:status])

                  # A run parked on a human approval/clarification is NOT idle —
                  # it is deliberately waiting. Suspend the watchdog while the
                  # run's gate has a pending decision and keep the clock fresh so
                  # the timer doesn't fire the instant the answer arrives.
                  last_real_event_at = clock.call if gate_pending?(run_id)

                  # Watchdog: if the run says "running" but the executor has
                  # gone silent for too long, escalate. Marks the row as
                  # failed (so the next /v1/runs query reflects truth) and
                  # appends a synthetic run.failed event so SSE consumers
                  # observe a proper terminal frame and can stop polling.
                  if idle_timeout && (clock.call - last_real_event_at) >= idle_timeout

                    handle_idle_timeout(repo, store, run_id, idle_timeout)
                    fresh = store.for_run(run_id, after_seq: cursor)
                    fresh.each do |event|
                      cursor = event[:seq]
                      y << format_event(event)
                    end
                    break
                  end

                  if clock.call - last_write_at >= HEARTBEAT_INTERVAL
                    y << HEARTBEAT_FRAME
                    last_write_at = clock.call
                  end

                  sleeper.call(POLL_INTERVAL)
                end
              rescue *DISCONNECT_ERRORS
                # Client (or proxy) closed the connection. Nothing to clean up:
                # falling out of the Enumerator block ends the stream and lets
                # Puma reclaim the thread.
                nil
              end
            end
          end

          # True when this run is currently blocked on a human approval or
          # clarification. The gate lives in the in-process GateRegistry; a nil
          # gate (run finished, or another worker) is simply "not pending".
          def gate_pending?(run_id)
            gate = ::Rubino::Run::GateRegistry.fetch(run_id)
            gate.respond_to?(:pending?) && gate.pending?
          rescue StandardError
            false
          end

          def configured_idle_timeout
            cfg = Rubino.configuration if defined?(Rubino) && Rubino.respond_to?(:configuration)
            value = cfg && cfg.respond_to?(:run_idle_event_timeout) ? cfg.run_idle_event_timeout : nil
            value.nil? ? DEFAULT_IDLE_EVENT_TIMEOUT : value
          rescue StandardError
            DEFAULT_IDLE_EVENT_TIMEOUT
          end

          # When the watchdog fires the run is, by definition, in an
          # inconsistent state — the worker thread is alive long enough that
          # systemd thinks the process is healthy but isn't emitting anymore.
          # We update the DB row first (authoritative) then append the
          # terminal event (best-effort; failure leaves the row consistent).
          def handle_idle_timeout(repo, store, run_id, timeout_seconds)
            error_message = "run idle: no new events for #{timeout_seconds.to_i}s"
            Rubino.logger.warn(event: "run.idle_timeout", run_id: run_id, timeout_s: timeout_seconds)
            repo.mark_failed!(run_id, error: error_message)
            run = repo.find(run_id)
            store.append(
              session_id: run && run[:session_id],
              run_id: run_id,
              type: "run.failed",
              payload: { error: error_message, reason: "idle_timeout" }
            )
          rescue StandardError => e
            Rubino.logger.error(event: "run.idle_timeout_error", run_id: run_id, error: e.class.name,
                                message: e.message)
          end

          def format_event(event)
            "id: #{event[:seq]}\nevent: #{event[:type]}\ndata: #{event[:payload_json]}\n\n"
          end
        end
      end
    end
  end
end
