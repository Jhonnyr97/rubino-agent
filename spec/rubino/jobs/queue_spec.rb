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

  # Regression for #346: the inline orphan reaper used to call Runner#run_job
  # directly — no lock, no terminal re-check — so two processes sharing one
  # RUBINO_HOME both saw the same `queued` orphans and DOUBLE-RAN them (each
  # billed ExtractMemoryJob ran twice). The reaper now CAS-claims every row
  # through the same lock #dequeue uses before running it, and run_job refuses a
  # row that already reached a terminal status. Each orphan runs at most once.
  describe "concurrent orphan reaping (#346)" do
    let(:config) do
      test_configuration("jobs" => { "mode" => "inline", "max_attempts" => 3,
                                     "poll_interval" => 1, "retry_backoff_seconds" => 0 })
    end

    before do
      allow(Rubino).to receive_messages(database: db_connection, configuration: config)
      # A real no-op handler so seeded orphans complete (not the resolution-
      # failure path). Each run_job execution records a job_runs row, which is
      # how the "exactly once" assertions count executions.
      noop = Class.new { define_method(:perform) { |_payload| nil } }
      Rubino::Jobs::Registry.register("TestJob", noop)
    end

    after { Rubino::Jobs::Registry.reset! }

    def seed_orphan
      now = Time.now.utc.iso8601
      id = SecureRandom.uuid
      db_connection.db[:jobs].insert(
        id: id, type: "TestJob", status: "queued", priority: 100,
        payload_json: "{}", attempts: 0, max_attempts: 3,
        run_at: now, created_at: now, updated_at: now
      )
      id
    end

    # #371 (residual of #346): the inline reap path used to read-then-run with no
    # atomic claim, so concurrent reapers double-executed the same queued rows.
    # FOUR reapers now race over the SAME N seeded orphans; the CAS claim in
    # reap_inline_orphans (queued -> running for exactly one caller) plus the
    # terminal-status re-check in run_job mean each job runs EXACTLY once — N
    # job_runs total, never 4N.
    it "runs each seeded orphan EXACTLY once across 4 concurrent reaps (#371)" do
      n = 12
      orphans = Array.new(n) { seed_orphan }

      # Four reapers race over the SAME seeded orphans, exactly as four processes
      # sharing one RUBINO_HOME would. Each run_job execution inserts one
      # job_runs row, so the count of job_runs per job_id is the execution count.
      threads = Array.new(4) do
        Thread.new { described_class.new(db: db_connection.db, config: config).reap_inline_orphans }
      end
      threads.each(&:join)

      runs_per_job = db_connection.db[:job_runs].group_and_count(:job_id).to_h { |r| [r[:job_id], r[:count]] }
      orphans.each do |id|
        expect(runs_per_job[id]).to eq(1), "job #{id} ran #{runs_per_job[id].inspect} times, expected exactly 1"
        expect(db_connection.db[:jobs].where(id: id).first[:status]).to eq("completed")
      end
      # Total executions == N, NOT 4N — the once-only proof at the aggregate level.
      expect(db_connection.db[:job_runs].count).to eq(n)
    end

    it "lets #claim! succeed for exactly one of two concurrent claimers" do
      id = seed_orphan
      results = Array.new(2)
      threads = Array.new(2) do |i|
        Thread.new do
          q = described_class.new(db: db_connection.db, config: config)
          results[i] = q.claim!(id, worker_id: "w#{i}")
        end
      end
      threads.each(&:join)

      expect(results.count(true)).to eq(1) # the CAS lets exactly one win
      expect(db_connection.db[:jobs].where(id: id).first[:status]).to eq("running")
    end

    it "refuses to re-run a job that already reached a terminal status" do
      id = seed_orphan
      db_connection.db[:jobs].where(id: id).update(status: "completed")

      # A direct run_job on an already-completed row must be a no-op: no second
      # (billed) execution, no new job_runs row.
      Rubino::Jobs::Runner.new(db: db_connection.db).run_job(id)

      expect(db_connection.db[:job_runs].where(job_id: id).count).to eq(0)
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

  # #76: a row a worker CLAIMED (queued -> running) and then abandoned — the
  # process died / was quit / hung — stays `running` with locked_by set and
  # attempts=0. Nothing re-picked it (the scan only sees `queued`), so it sat
  # forever and the queue grew across sessions. #reclaim_stale! recovers any
  # row whose lock is older than jobs.lock_lease_seconds.
  describe "#reclaim_stale!" do
    let(:config) do
      test_configuration(
        "jobs" => { "mode" => "manual", "max_attempts" => 3, "poll_interval" => 1,
                    "retry_backoff_seconds" => 0, "lock_lease_seconds" => 900 }
      )
    end

    def insert_running(locked_ago:, attempts: 0, max_attempts: 3)
      id = SecureRandom.uuid
      now = Time.now.utc.iso8601
      db_connection.db[:jobs].insert(
        id: id, type: "TestJob", status: "running", priority: 100,
        payload_json: "{}", attempts: attempts, max_attempts: max_attempts,
        locked_at: (Time.now - locked_ago).utc.iso8601, locked_by: "worker-dead",
        run_at: now, created_at: now, updated_at: now
      )
      id
    end

    it "re-queues a running row whose lock has outlived the lease" do
      stale = insert_running(locked_ago: 3600)

      expect(queue.reclaim_stale!).to eq(1)

      row = db_connection.db[:jobs].where(id: stale).first
      expect(row[:status]).to eq("queued")
      expect(row[:attempts]).to eq(1) # bumped so it can't loop forever
      expect(row[:locked_by]).to be_nil
    end

    it "leaves a freshly-locked running row alone (within the lease)" do
      fresh = insert_running(locked_ago: 5)

      expect(queue.reclaim_stale!).to eq(0)
      expect(db_connection.db[:jobs].where(id: fresh).first[:status]).to eq("running")
    end

    it "marks a stale row terminal (dead) once attempts are exhausted" do
      exhausted = insert_running(locked_ago: 3600, attempts: 2, max_attempts: 3)

      queue.reclaim_stale!

      # A genuinely stuck/poison job that keeps being reclaimed must eventually
      # stop being re-run rather than spin forever.
      expect(db_connection.db[:jobs].where(id: exhausted).first[:status]).to eq("dead")
    end

    it "is folded into #next_due_queued so the detached drain recovers orphans" do
      insert_running(locked_ago: 3600)

      # The drain scans via next_due_queued; reclaiming makes the orphan visible
      # as the next due row instead of staying stranded in `running`.
      row = queue.next_due_queued
      expect(row).not_to be_nil
      expect(row[:status]).to eq("queued")
    end

    # WHATIF-headless YELLOW-1: reclaim_stale! ran only on the dequeue/process/
    # drain write paths, so `jobs list` / `/jobs` showed a row stuck "running"
    # long past the lease (e.g. 43 min). The read entrypoints (#list, #counts)
    # now reclaim first so the displayed status/counts are honest.
    it "reclaims an expired-lease running row on the #list read path (YELLOW-1)" do
      stale = insert_running(locked_ago: 3600)

      rows = queue.list
      reclaimed = rows.find { |r| r[:id] == stale }
      expect(reclaimed[:status]).to eq("queued")
      expect(db_connection.db[:jobs].where(id: stale).first[:locked_by]).to be_nil
    end

    it "reclaims an expired-lease running row on the #counts read path (YELLOW-1)" do
      insert_running(locked_ago: 3600)

      # Pre-fix the header showed `1 running`; it must now read it as queued.
      counts = queue.counts
      expect(counts["running"]).to be_nil
      expect(counts["queued"]).to eq(1)
    end

    it "leaves a within-lease running row reported as running on #list" do
      fresh = insert_running(locked_ago: 5)

      rows = queue.list
      expect(rows.find { |r| r[:id] == fresh }[:status]).to eq("running")
    end
  end

  # WHATIF-headless RED-1: the headless one-shot drain used to sweep EVERY due/
  # queued/unlocked row in the table — a whole foreign backlog, each a full LLM
  # call. reap_inline_orphans now takes a +session_id+ that scopes the sweep to
  # the run's OWN post-turn jobs (matched by the session id serialized into the
  # payload), so a foreign backlog is left queued.
  describe "#reap_inline_orphans session scoping (RED-1)" do
    let(:config) do
      test_configuration("jobs" => { "mode" => "manual", "max_attempts" => 3,
                                     "poll_interval" => 1, "retry_backoff_seconds" => 0 })
    end

    before do
      allow(Rubino).to receive_messages(database: db_connection, configuration: config)
      noop = Class.new { define_method(:perform) { |_payload| nil } }
      Rubino::Jobs::Registry.register("TestJob", noop)
    end

    after { Rubino::Jobs::Registry.reset! }

    def seed_queued(session_id)
      id = SecureRandom.uuid
      now = Time.now.utc.iso8601
      db_connection.db[:jobs].insert(
        id: id, type: "TestJob", status: "queued", priority: 100,
        payload_json: JSON.generate(session_id: session_id),
        attempts: 0, max_attempts: 3, locked_by: nil,
        run_at: now, created_at: now, updated_at: now
      )
      id
    end

    it "drains only the current session's own rows, leaving a foreign backlog queued" do
      own     = seed_queued("sess-own")
      foreign = seed_queued("sess-foreign")

      queue.reap_inline_orphans(session_id: "sess-own")

      statuses = db_connection.db[:jobs].to_h { |j| [j[:id], j[:status]] }
      expect(statuses[own]).to eq("completed")
      expect(statuses[foreign]).to eq("queued") # NOT drained — belongs to another run
    end

    it "with no session_id keeps the whole-queue sweep (inline-boot recovery)" do
      a = seed_queued("sess-a")
      b = seed_queued("sess-b")

      queue.reap_inline_orphans

      statuses = db_connection.db[:jobs].to_h { |j| [j[:id], j[:status]] }
      expect(statuses[a]).to eq("completed")
      expect(statuses[b]).to eq("completed")
    end
  end
end
