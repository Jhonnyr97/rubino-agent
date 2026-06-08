# frozen_string_literal: true

RSpec.describe Rubino::Jobs::Queue do
  let(:db_connection) { test_database }
  let(:config) do
    test_configuration(
      "jobs" => {
        "mode" => "manual",
        "max_attempts" => 3,
        "poll_interval" => 1,
        "retry_backoff_seconds" => 0  # no backoff so dequeue finds it immediately
      }
    )
  end
  let(:queue) { described_class.new(db: db_connection.db, config: config) }

  before { db_connection.db[:job_runs].delete; db_connection.db[:jobs].delete }

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
      id2 = queue.enqueue("Job2", {})
      queue.dequeue(worker_id: "w1")
      # Job2 is now "running", Job1 is still "queued"
      # (dequeue picks first by priority/run_at)
      running = queue.list(status: "running")
      expect(running.size).to eq(1)
    end
  end
end
