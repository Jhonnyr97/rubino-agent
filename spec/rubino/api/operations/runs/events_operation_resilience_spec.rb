# frozen_string_literal: true

require "spec_helper"

# Covers B3 (thread cleanup on client disconnect) and B4 (15s heartbeat).
# The existing happy-path coverage lives in events_operation_spec.rb; this
# file isolates the resilience seams (clock + sleeper) so we can simulate
# proxy timeouts and broken pipes without sleeping in real wall-clock time.
RSpec.describe Rubino::API::Operations::Runs::EventsOperation do
  before { with_test_db }

  let(:session_repo) { Rubino::Session::Repository.new }
  let(:run_repo)     { Rubino::Run::Repository.new }
  let(:event_store)  { Rubino::Run::EventStore.new }

  def create_queued_run
    session = session_repo.create(source: "api")
    run_repo.create(session_id: session[:id], input_text: "x")
  end

  describe "client disconnect (B3)" do
    it "breaks out of the polling loop when a write raises Errno::EPIPE" do
      run = create_queued_run
      event_store.append(session_id: run[:session_id], run_id: run[:id],
                         type: "message.delta", payload: { text: "hi" })

      store_spy = instance_double(Rubino::Run::EventStore)
      # First poll: return the persisted event (the replay phase).
      # If the rescue did not break the loop, this would be called again
      # after the EPIPE — the strict double makes that a failure.
      allow(store_spy).to receive(:for_run).and_return(
        [{ seq: 1, type: "message.delta", payload_json: '{"text":"hi"}' }]
      )

      operation = described_class.new(repository: run_repo, event_store: store_spy)
      _status, _headers, body = operation.call(make_request(params: { id: run[:id] }))

      expect do
        body.each { |_chunk| raise Errno::EPIPE, "broken pipe" }
      end.not_to raise_error
      # One replay call only; no polling after the simulated disconnect.
      expect(store_spy).to have_received(:for_run).once
    end

    it "also rescues IOError and Errno::ECONNRESET" do
      run = create_queued_run
      event_store.append(session_id: run[:session_id], run_id: run[:id],
                         type: "message.delta", payload: { text: "hi" })

      _, _, body1 = described_class.new(repository: run_repo, event_store: event_store)
                                   .call(make_request(params: { id: run[:id] }))
      expect { body1.each { |_| raise IOError, "closed stream" } }.not_to raise_error

      _, _, body2 = described_class.new(repository: run_repo, event_store: event_store)
                                   .call(make_request(params: { id: run[:id] }))
      expect { body2.each { |_| raise Errno::ECONNRESET, "reset" } }.not_to raise_error
    end
  end

  describe "heartbeat (B4)" do
    it "emits a heartbeat comment frame after >= 15s of silence" do
      run = create_queued_run # queued = non-terminal, so the loop keeps polling

      # Virtual monotonic clock: each call advances by 20s, which crosses the
      # 15s threshold on the very first loop iteration.
      ticks = [0.0, 20.0, 21.0]
      clock = -> { ticks.shift || 1000.0 }
      sleeper = ->(_s) {} # don't actually sleep

      operation = described_class.new(
        repository: run_repo, event_store: event_store,
        clock: clock, sleeper: sleeper
      )
      _, _, body = operation.call(make_request(params: { id: run[:id] }))

      # `first` pulls one chunk and leaves the Fiber suspended — exactly
      # what Puma would do on a long-lived stream.
      expect(body.first).to eq(": heartbeat\n\n")
    end

    it "does not emit a heartbeat when the gap is under 15s" do
      run = create_queued_run

      # Always within the window, but mark the run terminal after one poll
      # so the loop exits and we can inspect what was yielded.
      clock = -> { 1.0 }
      sleeper = ->(_s) { run_repo.mark_completed!(run[:id]) }

      operation = described_class.new(
        repository: run_repo, event_store: event_store,
        clock: clock, sleeper: sleeper
      )
      _, _, body = operation.call(make_request(params: { id: run[:id] }))

      expect(body.to_a).to be_empty
    end
  end

  describe "idle event watchdog" do
    it "marks the run failed and emits a synthetic run.failed when no events arrive within idle_event_timeout" do
      run = create_queued_run

      # Virtual clock that crosses the 60s idle window on the first poll.
      ticks = [0.0, 70.0, 71.0, 72.0, 73.0]
      clock = -> { ticks.shift || 1000.0 }
      sleeper = ->(_s) {}

      operation = described_class.new(
        repository: run_repo, event_store: event_store,
        clock: clock, sleeper: sleeper, idle_event_timeout: 60.0
      )
      _, _, body = operation.call(make_request(params: { id: run[:id] }))
      chunks = body.to_a

      reloaded = run_repo.find(run[:id])
      expect(reloaded[:status]).to eq("failed")
      expect(reloaded[:error]).to include("no new events for 60s")

      # The synthetic run.failed frame is appended to the store and yielded
      # before the stream closes, so SSE consumers see a proper terminal.
      run_failed_chunks = chunks.select { |c| c.include?("event: run.failed") }
      expect(run_failed_chunks.length).to eq(1)
      expect(run_failed_chunks.first).to include("idle_timeout")
    end

    it "does NOT reap a run that is parked on a pending human approval (Option C)" do
      run = create_queued_run

      # Register a gate and park a thread in #await so the run is legitimately
      # waiting on a human, not silently dead. The watchdog must skip it.
      gate = Rubino::Run::ApprovalGate.new
      Rubino::Run::GateRegistry.register(run[:id], gate)
      gate.register("decision-id")
      waiter = Thread.new { gate.await("decision-id", timeout: 5) }
      sleep 0.01 until gate.pending? || !waiter.alive?

      begin
        # Clock crosses the idle window repeatedly; without the gate check this
        # would mark the run failed. Mark terminal after a few polls so the
        # loop exits and we can inspect the row.
        polls = 0
        clock = -> { polls * 70.0 }
        sleeper = lambda do |_s|
          polls += 1
          run_repo.mark_completed!(run[:id]) if polls > 3
        end

        operation = described_class.new(
          repository: run_repo, event_store: event_store,
          clock: clock, sleeper: sleeper, idle_event_timeout: 60.0
        )
        _, _, body = operation.call(make_request(params: { id: run[:id] }))
        body.to_a

        # The run was never promoted to failed by the watchdog — it is completed
        # (our sleeper) or still queued, but crucially NOT idle-failed.
        expect(run_repo.find(run[:id])[:status]).not_to eq("failed")
      ensure
        gate.decide("decision-id", "once")
        waiter.join(2)
        Rubino::Run::GateRegistry.unregister(run[:id])
      end
    end

    it "does NOT reap a long-running tool that keeps emitting tool.progress heartbeats" do
      run = create_queued_run

      # A long, silent tool (summarize_file: ~30 sequential aux-LLM calls) emits
      # NO terminal events for minutes, but its stream_chunk now mirrors onto the
      # bus as tool.progress. Each progress event is a real run-event, so it
      # resets the idle watchdog. Here every poll appends one fresh progress
      # event well inside the 60s window; the clock advances 30s/poll so without
      # the heartbeat the run would be reaped, but with it it never goes idle.
      polls = 0
      clock = -> { polls * 30.0 }
      sleeper = lambda do |_s|
        polls += 1
        if polls > 4
          run_repo.mark_completed!(run[:id])
        else
          event_store.append(session_id: run[:session_id], run_id: run[:id],
                             type: "tool.progress",
                             payload: { name: "summarize_file", chunk: "summarizing chunk #{polls}/30" })
        end
      end

      operation = described_class.new(
        repository: run_repo, event_store: event_store,
        clock: clock, sleeper: sleeper, idle_event_timeout: 60.0
      )
      _, _, body = operation.call(make_request(params: { id: run[:id] }))
      chunks = body.to_a

      # The run completed normally; the watchdog never fired despite no terminal
      # events for 120s of virtual time, because progress kept the stream alive.
      expect(run_repo.find(run[:id])[:status]).to eq("completed")
      expect(chunks.select { |c| c.include?("event: tool.progress") }.length).to eq(4)
      expect(chunks).not_to include(a_string_including("idle_timeout"))
    end

    it "is disabled when idle_event_timeout is nil — long-silent runs stay running" do
      run = create_queued_run

      ticks = [0.0, 600.0, 601.0]
      clock = -> { ticks.shift || 1000.0 }
      sleeper = ->(_s) { run_repo.mark_completed!(run[:id]) }

      operation = described_class.new(
        repository: run_repo, event_store: event_store,
        clock: clock, sleeper: sleeper, idle_event_timeout: nil
      )
      _, _, body = operation.call(make_request(params: { id: run[:id] }))
      body.to_a

      expect(run_repo.find(run[:id])[:status]).to eq("completed")
    end
  end

  describe "normal event flow" do
    it "still streams real events without disturbance" do
      session = session_repo.create(source: "api")
      run = run_repo.create(session_id: session[:id], input_text: "x")
      run_repo.mark_completed!(run[:id])
      event_store.append(session_id: run[:session_id], run_id: run[:id],
                         type: "message.delta", payload: { text: "hello" })
      event_store.append(session_id: run[:session_id], run_id: run[:id],
                         type: "run.completed", payload: { status: "ok" })

      _, _, body = described_class.call(make_request(params: { id: run[:id] }))
      chunks = body.to_a

      expect(chunks.length).to eq(2)
      expect(chunks.first).to include("event: message.delta")
      expect(chunks.last).to include("event: run.completed")
      expect(chunks).not_to include(": heartbeat\n\n")
    end
  end
end
