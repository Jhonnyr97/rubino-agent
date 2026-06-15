# frozen_string_literal: true

# Headless one-shot post-turn job DRAIN (#358) and interrupt PARTIAL echo
# (#349). In headless `-q`/prompt mode there is no live REPL to pick the
# post-turn jobs up at a future enqueue, and the process exits the instant
# run! returns — so without an explicit drain the memory-extract job piled up
# `queued` and never ran (memory_facts stayed 0). And on SIGINT the partial the
# Loop persisted never reached stdout because run! raised before the answer was
# printed.
RSpec.describe Rubino::CLI::ChatCommand do
  let(:db)       { test_database }
  let(:null_ui)  { Rubino::UI::Null.new }
  let(:fake_llm) { FakeLLMAdapter.new }

  # #358 — the post-turn ExtractMemoryJob must actually RUN before a headless
  # one-shot exits. Auto-extract ON (so the job is enqueued), skill-distill OFF
  # (keep the scripted FakeLLM queue clean), inline jobs so the detached worker
  # drains synchronously when joined.
  describe "draining post-turn jobs before a headless exit (#358)" do
    let(:config) do
      # interval 1 = every turn, so this single-turn DRAIN test always enqueues
      # the memory job (the throttle itself is covered in lifecycle_spec, #412).
      mem    = Rubino::Config::Defaults.to_hash["memory"].merge("auto_extract" => true, "auto_extract_interval" => 1)
      skills = Rubino::Config::Defaults.to_hash["skills"].merge("auto_distill" => false)
      jobs   = { "mode" => "inline", "max_attempts" => 3, "poll_interval" => 1, "retry_backoff_seconds" => 0 }
      test_configuration("memory" => mem, "skills" => skills, "jobs" => jobs)
    end

    # The memory backend the ExtractMemoryJob (and load_memory) drive. #extract
    # records that it ran and returns one stored fact so the job completes
    # exactly as a real extraction would.
    let(:extracted) { [] }
    let(:backend) do
      facts = extracted
      bk = instance_double(Rubino::Memory::Backends::Sqlite)
      allow(bk).to receive_messages(user_profile: nil, project_context: nil, retrieve: [])
      allow(bk).to receive(:extract) do |session_id|
        facts.push(session_id)
        [{ id: "fact-1234", content: "user prefers tabs" }]
      end
      bk
    end

    before do
      allow(Rubino).to receive_messages(database: db, configuration: config)
      allow(Rubino::LLM::RubyLLMAdapter).to receive(:new).and_return(fake_llm)
      allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(true)
      allow(Rubino::Memory::Backends).to receive(:build).and_return(backend)
      Rubino.ui = null_ui
    end

    it "runs the ExtractMemoryJob to completion before exiting (the fact is stored)" do
      fake_llm.enqueue_text("Noted — I prefer tabs.")

      expect do
        described_class.new("query" => "remember I prefer tabs").execute
      rescue SystemExit => e
        raise "expected a clean exit-0 run, got status #{e.status}"
      end.to output(/prefer tabs/).to_stdout

      # The post-turn extraction actually RAN (pre-fix it sat queued forever).
      expect(extracted).not_to be_empty
      memory_jobs = db.db[:jobs].where(type: "ExtractMemoryJob").all
      expect(memory_jobs.size).to eq(1)
      expect(memory_jobs.first[:status]).to eq("completed")
      # No post-turn row is left stuck queued/running after a headless exit.
      expect(db.db[:jobs].where(status: %w[queued running]).count).to eq(0)
    end
  end

  # #349 — a one-shot interrupt must EMIT the persisted partial. The Loop stored
  # the answer-so-far (metadata interrupted:true) but run! raised before the
  # answer was printed, so `rubino -q` produced 0 bytes on SIGINT. Drive the
  # persistence directly (don't depend on a live model): seed the interrupted
  # partial, stub run! to raise, and assert it reaches stdout / the JSON result.
  describe "printing the interrupted partial (#349)" do
    let(:partial) { "Here is the answer so far before the interrupt" }
    let(:session) { { id: "sess-349", model: "fake-model" } }
    let(:runner)  { instance_double(Rubino::Agent::Runner) }

    before do
      allow(Rubino).to receive(:database).and_return(db)
      allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(true)
      Rubino.ui = null_ui

      # A real session row so the messages FK (PRAGMA foreign_keys=ON) is
      # satisfied when the interrupted partial is persisted below.
      now = Time.now.utc.iso8601
      db.db[:sessions].insert(
        id: session[:id], source: "cli", model: session[:model], status: "active",
        message_count: 0, token_count: 0, created_at: now, updated_at: now
      )

      # The partial the Loop would have persisted mid-stream before the cancel.
      Rubino::Session::Store.new(db: db.db).create(
        session_id: session[:id], role: "assistant", content: partial,
        metadata: { interrupted: true }
      )

      allow(Rubino::Agent::Runner).to receive(:new).and_return(runner)
      allow(runner).to receive(:cancel!)
      allow(runner).to receive(:session).and_return(session)
      allow(runner).to receive(:run!).and_raise(Rubino::Interrupted)
    end

    it "prints the persisted partial to stdout then exits 130 (text mode)" do
      status = nil
      expect do
        described_class.new("query" => "hi").execute
      rescue SystemExit => e
        status = e.status
      end.to output(/Here is the answer so far/).to_stdout

      expect(status).to eq(130)
    end

    it "carries the partial in the result envelope then exits 130 (--json)" do
      status = nil
      expect do
        described_class.new("query" => "hi", "json" => true).execute
      rescue SystemExit => e
        status = e.status
      end.to output(/Here is the answer so far/).to_stdout

      expect(status).to eq(130)
    end
  end
end
