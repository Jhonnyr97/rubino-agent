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
