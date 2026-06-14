# frozen_string_literal: true

RSpec.describe Rubino::Jobs::Queue do
  let(:db_connection) { test_database }
  let(:config) do
    test_configuration(
      "jobs" => {
        "mode" => "manual",
        "max_attempts" => 3,
        "poll_interval" => 1,
        "retry_backoff_seconds" => 0 # no backoff so dequeue finds it immediately
      }
    )
  end
  let(:queue) { described_class.new(db: db_connection.db, config: config) }

  before do
    db_connection.db[:job_runs].delete
    db_connection.db[:jobs].delete
  end

  describe "#enqueue" do
    it "creates a job with queued status" do
      id = queue.enqueue("TestJob", { foo: "bar" })
      expect(id).not_to be_nil

      jobs = queue.list
      expect(jobs.size).to eq(1)
      expect(jobs.first[:type]).to eq("TestJob")
      expect(jobs.first[:status]).to eq("queued")
    end

    it "does not execute inline when mode is manual" do
      expect(Rubino::Jobs::Runner).not_to receive(:new)
      queue.enqueue("TestJob", { foo: "bar" })
    end
  end

  describe "inline mode" do
    let(:config) do
      test_configuration(
        "jobs" => {
          "mode" => "inline",
          "max_attempts" => 3,
          "poll_interval" => 1,
          "retry_backoff_seconds" => 0
        }
      )
    end

    before do
      # The inline Runner builds its own Queue against the global database
      # and configuration — pin both to this spec's.
      allow(Rubino).to receive_messages(database: db_connection, configuration: config)
    end

    # Regression for #81: the handler used to self-register only when its
    # constant happened to be loaded; with Zeitwerk lazy autoload nothing
    # touched ExtractMemoryJob before the inline Runner ran at enqueue time,
    # so every auto-extract turn failed with "No handler registered" and the
    # job sat "queued" forever. The Registry now resolves handlers from the
    # Jobs::Handlers namespace on demand, independent of load order.
    it "completes an inline ExtractMemoryJob even when nothing pre-registered its handler (#81)" do
      Rubino::Jobs::Registry.reset! # simulate a clean process: no constant touched yet
      backend = instance_double(Rubino::Memory::Backends::Sqlite, extract: [])
      allow(Rubino::Memory::Backends).to receive(:build).and_return(backend)

      id = queue.enqueue("ExtractMemoryJob", { session_id: "sid-1" })

      job = db_connection.db[:jobs].where(id: id).first
      expect(job[:status]).to eq("completed")
      expect(job[:last_error]).to be_nil
      expect(backend).to have_received(:extract).with("sid-1")
    end

    # Regression for #84: an inline failure used to go back to "queued", but
    # nothing ever re-runs it in inline mode — the row was orphaned forever.
    # Inline failures are now terminal ("failed") so `jobs list` is honest.
    it "marks an inline failure terminal instead of re-queueing it forever (#84)" do
      id = queue.enqueue("NoSuchJob", {})

      job = db_connection.db[:jobs].where(id: id).first
      expect(job[:status]).to eq("failed")
      expect(job[:last_error]).to include("No handler registered")
    end

    # Regression for #224 (re-#84): in inline mode run_job is invoked directly
    # (never locked) and Interrupt is not a StandardError, so a turn whose
    # post-turn extraction was cut short — e.g. the user quit the session while
    # "polishing · memory" was still running — leaves a row at status=queued,
    # attempts=0, locked_by=nil, last_error=nil. Nothing re-runs it; #84's fix
    # only made inline *failures* terminal, never reaped an orphaned *queued*
    # row. The next inline enqueue (the next `rubino` turn) must drain it. The
    # original #84 test never covered this state — it asserted only the failure
    # path.
    context "when reaping orphaned queued rows (#224)" do
      before do
        # A trivial no-op handler so enqueued TestJobs complete (vs. the
        # handler-resolution failure path covered by the #84 test above).
        Rubino::Jobs::Registry.register("TestJob", Class.new { def perform(_payload) = nil })
      end

      after { Rubino::Jobs::Registry.reset! }

      it "drains a queued row orphaned by a prior interrupted inline run on the next enqueue (#224)" do
        now = Time.now.utc.iso8601
        orphan = SecureRandom.uuid
        # An ExtractMemoryJob left exactly as an interrupted inline run would:
        # queued, never locked, no attempts, no error.
        db_connection.db[:jobs].insert(
          id: orphan, type: "TestJob", status: "queued", priority: 100,
          payload_json: "{}", attempts: 0, max_attempts: 3,
          run_at: now, created_at: now, updated_at: now
        )
        # Pre-fix: it stays queued across runs; only `jobs process` clears it.
        expect(queue.pending_count).to eq(1)

        # The next turn boots the inline runner again by enqueuing a fresh job.
        fresh = queue.enqueue("TestJob", { data: 1 })

        jobs = db_connection.db[:jobs].to_h { |j| [j[:id], j[:status]] }
        # The orphan is now drained terminally, not left queued forever.
        expect(jobs[orphan]).to eq("completed")
        expect(jobs[fresh]).to eq("completed")
        expect(queue.pending_count).to eq(0)
      end

      # Regression for J1 (poison payload): a queued row whose payload_json is
      # NOT valid JSON used to crash the inline enqueue path. run_job parsed the
      # payload OUTSIDE its begin/rescue, so JSON::ParserError escaped through
      # reap_inline_orphans → enqueue → the live turn's outer rescue (marking
      # the whole interaction FAILED after the answer was produced). The corrupt
      # row never reached fail!, stayed queued forever, and re-poisoned every
      # subsequent turn — pending grew unbounded (2→3→4). The fix: a bad payload
      # is now failure-isolated terminally (fail!), and the reap loop guards
      # each row so one poison can never abort the enqueue.
      it "drains a corrupt-payload queued orphan terminally without aborting the live enqueue (J1)" do
        now = Time.now.utc.iso8601
        corrupt = SecureRandom.uuid
        db_connection.db[:jobs].insert(
          id: corrupt, type: "TestJob", status: "queued", priority: 100,
          payload_json: "this is not json {{{", attempts: 0, max_attempts: 3,
          run_at: now, created_at: now, updated_at: now
        )

        # Three real turns: each must complete the live enqueue (not raise),
        # the corrupt row must become terminal, and pending must NOT grow.
        3.times do |i|
          expect { queue.enqueue("TestJob", { turn: i }) }.not_to raise_error
          row = db_connection.db[:jobs].where(id: corrupt).first
          expect(row[:status]).not_to eq("queued") # terminal, not stuck
          expect(row[:status]).to(satisfy { |s| %w[failed dead].include?(s) })
        end

        # The poison row consumed at most its max_attempts; pending stays bounded
        # (the corrupt row is no longer counted, fresh turns completed).
        expect(queue.pending_count).to eq(0)
      end

      # The reap loop must not let an unexpected raise from one orphan abort the
      # whole inline enqueue — defence-in-depth mirroring Scheduler#schedule.
      it "isolates a raising orphan in the reap loop so the live enqueue survives (J1)" do
        now = Time.now.utc.iso8601
        boom = SecureRandom.uuid
        db_connection.db[:jobs].insert(
          id: boom, type: "TestJob", status: "queued", priority: 100,
          payload_json: "{}", attempts: 0, max_attempts: 3,
          run_at: now, created_at: now, updated_at: now
        )
        # Force run_job to raise for the orphan but not for the fresh enqueue.
        # The reap loop builds its own Runner(db:) — stub a real instance and
        # have it raise only for the poison row.
        reaping_runner = Rubino::Jobs::Runner.new(db: db_connection.db)
        allow(Rubino::Jobs::Runner).to receive(:new).and_call_original
        allow(Rubino::Jobs::Runner).to receive(:new).with(db: db_connection.db).and_return(reaping_runner)
        original_run = reaping_runner.method(:run_job)
        allow(reaping_runner).to receive(:run_job) do |jid|
          raise "boom draining orphan" if jid == boom

          original_run.call(jid)
        end

        fresh = nil
        expect { fresh = queue.enqueue("TestJob", { data: 1 }) }.not_to raise_error
        expect(db_connection.db[:jobs].where(id: fresh).first[:status]).to eq("completed")
      end

      it "does not reap a queued row that is not yet due (run_at in the future)" do
        future = (Time.now + 3600).utc.iso8601
        now = Time.now.utc.iso8601
        scheduled = SecureRandom.uuid
        db_connection.db[:jobs].insert(
          id: scheduled, type: "TestJob", status: "queued", priority: 100,
          payload_json: "{}", attempts: 0, max_attempts: 3,
          run_at: future, created_at: now, updated_at: now
        )

        queue.enqueue("TestJob", { data: 1 })

        expect(db_connection.db[:jobs].where(id: scheduled).first[:status]).to eq("queued")
      end
    end
  end

  describe "#dequeue" do
    it "returns and locks the next job" do
      queue.enqueue("TestJob", { data: 1 })
      job = queue.dequeue(worker_id: "test-worker")
      expect(job[:status]).to eq("running")
      expect(job[:locked_by]).to eq("test-worker")
    end

    it "returns nil when queue is empty" do
      expect(queue.dequeue(worker_id: "test")).to be_nil
    end

    it "does not return already-locked jobs to another worker" do
      queue.enqueue("TestJob", {})
      queue.dequeue(worker_id: "worker-1")
      second = queue.dequeue(worker_id: "worker-2")
      expect(second).to be_nil
    end
  end

  describe "#complete!" do
    it "marks job as completed and clears lock" do
      id = queue.enqueue("TestJob", {})
      queue.dequeue(worker_id: "w1")
      queue.complete!(id)

      job = queue.list.first
      expect(job[:status]).to eq("completed")
      expect(job[:locked_by]).to be_nil
    end
  end

  describe "#fail!" do
    it "increments attempts and re-queues if under max_attempts" do
      id = queue.enqueue("TestJob", {})
      queue.dequeue(worker_id: "w1")
      queue.fail!(id, error: "something broke")

      job = queue.list.first
      expect(job[:status]).to eq("queued")
      expect(job[:attempts]).to eq(1)
      expect(job[:last_error]).to eq("something broke")
    end

    it "marks as dead after max_attempts exhausted" do
      id = queue.enqueue("TestJob", {})

      3.times do
        # Re-lock manually each time since dequeue with 0-backoff should find it
        db_connection.db[:jobs].where(id: id).update(status: "queued", locked_at: nil, locked_by: nil)
        queue.dequeue(worker_id: "w1")
        queue.fail!(id, error: "still failing")
      end

      job = queue.list.first
      expect(job[:status]).to eq("dead")
      expect(job[:attempts]).to eq(3)
    end
  end

  describe "#pending_count" do
    it "counts only queued jobs" do
      queue.enqueue("Job1", {})
      queue.enqueue("Job2", {})
      expect(queue.pending_count).to eq(2)
    end

    it "excludes running and completed jobs" do
      id = queue.enqueue("Job1", {})
      queue.dequeue(worker_id: "w1")
      queue.complete!(id)
      queue.enqueue("Job2", {})

      expect(queue.pending_count).to eq(1)
    end
  end

  describe "#failed_count" do
    it "counts failed AND dead jobs, not queued/completed ones (#186)" do
      done   = queue.enqueue("Job1", {})
      failed = queue.enqueue("Job2", {})
      dead   = queue.enqueue("Job3", {})
      queue.enqueue("Job4", {})
      db_connection.db[:jobs].where(id: done).update(status: "completed")
      db_connection.db[:jobs].where(id: failed).update(status: "failed")
      db_connection.db[:jobs].where(id: dead).update(status: "dead")

      expect(queue.failed_count).to eq(2)
    end

    it "is zero on an empty queue" do
      expect(queue.failed_count).to eq(0)
    end
  end

  describe "#list" do
    it "filters by status" do
      queue.enqueue("Job1", {})
      queue.enqueue("Job2", {})
      queue.dequeue(worker_id: "w1")
      # Job2 is now "running", Job1 is still "queued"
      # (dequeue picks first by priority/run_at)
      running = queue.list(status: "running")
      expect(running.size).to eq(1)
    end
  end
end
