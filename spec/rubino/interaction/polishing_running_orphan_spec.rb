# frozen_string_literal: true

# Reproduction for FINDING #76: post-turn jobs enqueue but never drain.
#
# In interactive mode the post-turn jobs are PERSISTED queued (drain_inline:
# false) and swept by the detached polishing worker. A worker CLAIMS a row
# (queued -> running, stamping locked_by) before executing it. If that process
# dies / is quit / hangs while a row is `running`, the row is stranded:
#
#   * Queue#next_due_queued (what the polishing drain scans) only sees
#     status == "queued", so it never re-picks a `running` row.
#   * Queue#reap_inline_orphans (the only recovery path) (a) only runs on the
#     INLINE enqueue path, never in interactive mode, and (b) only reaps
#     status == "queued" rows anyway.
#
# So a `running` orphan with attempts=0 sits forever — exactly the
# "queued/running since 09:17, 0 attempts, queue grew" the QA tester saw.
RSpec.describe Rubino::Interaction::Polishing do
  let(:db_connection) { test_database }
  let(:config) do
    test_configuration("jobs" => { "mode" => "inline", "max_attempts" => 3,
                                   "poll_interval" => 1, "retry_backoff_seconds" => 0 })
  end
  let(:queue)     { Rubino::Jobs::Queue.new(db: db_connection.db, config: config) }
  let(:polishing) { described_class.new(config: config) }
  let(:ui)        { Rubino::UI::Null.new }
  let(:bus)       { Rubino::Interaction::EventBus.new }

  before do
    allow(Rubino).to receive(:database).and_return(db_connection)
    db_connection.db[:job_runs].delete
    db_connection.db[:jobs].delete
  end

  after { Rubino::Jobs::Registry.reset! }

  describe "#start draining a row orphaned in `running` by a crashed worker (#76)" do
    # A row another (now-dead) worker left mid-flight: status="running",
    # locked_by set, attempts=0. The drain that runs on the next interactive
    # turn must recover and run it; pre-fix it is stranded forever.
    it "recovers and runs the stale running orphan alongside the fresh row" do
      ran = []
      Rubino::Jobs::Registry.register(
        "PolishTestJob",
        Class.new { define_method(:perform) { |p| ran.push(p[:n]) } }
      )

      now = Time.now.utc.iso8601
      stale = SecureRandom.uuid
      # Left exactly as a worker that claimed the row and then died: running,
      # locked, well past any reasonable lock lease, never completed.
      db_connection.db[:jobs].insert(
        id: stale, type: "PolishTestJob", status: "running", priority: 100,
        payload_json: '{"n":1}', attempts: 0, max_attempts: 3,
        locked_at: (Time.now - 3600).utc.iso8601, locked_by: "worker-dead-123",
        run_at: now, created_at: now, updated_at: now
      )

      # A fresh interactive turn enqueues its own row and kicks the polishing
      # worker — which must sweep BOTH the new row and the stale orphan.
      queue.enqueue("PolishTestJob", { n: 2 }, drain_inline: false)
      polishing.start(ui: ui, event_bus: bus)
      polishing.wait(5)

      expect(ran).to contain_exactly(1, 2)
      statuses = db_connection.db[:jobs].to_h { |j| [j[:id], j[:status]] }
      expect(statuses[stale]).to eq("completed")
      # Nothing left hanging in queued/running.
      expect(queue.counts.keys).to contain_exactly("completed")
    end
  end
end
