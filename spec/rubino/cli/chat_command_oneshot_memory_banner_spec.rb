# frozen_string_literal: true

# #372 (regression of #358) — the inline post-turn memory banner must NOT leak
# to stdout in a headless one-shot run. ExtractMemoryJob#confirm calls
# Rubino.ui.note("✓ saved to memory …"). The detached polishing worker already
# runs the extraction under the runner's Null UI, but the post-run inline
# orphan-reaper inside #drain_post_turn_jobs! runs on the MAIN thread with no UI
# binding — so any job it sweeps (a row a prior interrupted run orphaned, or one
# the worker didn't reach) resolved Rubino.ui to the GLOBAL stdout-backed
# UI::CLI, landing the "✓ saved to memory" banner on stdout and polluting
# `answer=$(rubino prompt …)`. The reaper is now wrapped in the headless Null
# UI, so headless stdout stays exactly the model answer.
RSpec.describe Rubino::CLI::ChatCommand do
  let(:db)     { test_database }
  let(:config) { test_configuration("jobs" => { "mode" => "inline", "max_attempts" => 3,
                                                "poll_interval" => 1, "retry_backoff_seconds" => 0 }) }

  let(:backend) do
    bk = instance_double(Rubino::Memory::Backends::Sqlite)
    allow(bk).to receive_messages(user_profile: nil, project_context: nil, retrieve: [])
    # A stored fact so #confirm actually fires the leaking note.
    allow(bk).to receive(:extract).and_return([{ id: "fact-1234", content: "user prefers tabs" }])
    bk
  end

  before do
    allow(Rubino).to receive_messages(database: db, configuration: config)
    allow(Rubino::Memory::Backends).to receive(:build).and_return(backend)
    # CRITICAL: the GLOBAL UI is a stdout-backed CLI — the very adapter the
    # leaking note would print through. The fix must keep the orphan-reaper's
    # job confirmations OFF this stdout regardless.
    Rubino.ui = Rubino::UI::CLI.new
  end

  def capture_stdout
    orig = $stdout
    buf = StringIO.new
    $stdout = buf
    yield
    buf.string
  ensure
    $stdout = orig
  end

  it "drains the inline orphan ExtractMemoryJob WITHOUT leaking its banner to stdout (#372)" do
    # A real session so the job has a target.
    session = Rubino::Session::Repository.new(db: db.db).create(source: "cli", model: "fake")
    # An ORPHAN ExtractMemoryJob left queued (the reaper's job), drain_inline:false
    # so it stays queued for the reaper rather than running on enqueue.
    Rubino::Jobs::Queue.new(db: db.db, config: config)
                       .enqueue("ExtractMemoryJob", { session_id: session[:id] }, drain_inline: false)

    # A runner with NO detached worker, so the orphan is drained by the
    # main-thread reaper inside #drain_post_turn_jobs! — the exact leak path.
    runner = instance_double(Rubino::Agent::Runner, polishing: nil)
    headless_ui = Rubino::UI::Null.new
    cmd = described_class.new

    out = capture_stdout do
      cmd.send(:drain_post_turn_jobs!, runner, headless_ui)
    end

    # The extraction ran (the job completed) but its confirmation banner never
    # reached stdout — stdout is empty.
    expect(out).not_to include("saved to memory")
    expect(out).to eq("")
    job = db.db[:jobs].where(type: "ExtractMemoryJob").first
    expect(job[:status]).to eq("completed")
  end

  it "WOULD leak to the bound UI without the headless wrap (proves the seam)" do
    # Sanity that the note path is live: with NO headless UI passed, the reaper
    # drains under the global CLI and the banner reaches stdout. This pins that
    # the regression test above is actually exercising the suppression.
    session = Rubino::Session::Repository.new(db: db.db).create(source: "cli", model: "fake")
    Rubino::Jobs::Queue.new(db: db.db, config: config)
                       .enqueue("ExtractMemoryJob", { session_id: session[:id] }, drain_inline: false)

    runner = instance_double(Rubino::Agent::Runner, polishing: nil)
    cmd = described_class.new

    out = capture_stdout do
      cmd.send(:drain_post_turn_jobs!, runner) # no headless_ui ⇒ global CLI
    end

    expect(out).to include("saved to memory")
  end
end
