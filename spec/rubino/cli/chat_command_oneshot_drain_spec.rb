# frozen_string_literal: true

# Headless one-shot post-turn job DRAIN (#358) and interrupt PARTIAL echo
# (#349). In headless `-q`/prompt mode there is no live REPL to pick the
# post-turn jobs up at a future enqueue, and the process exits the instant
# run! returns — so without an explicit drain the post-turn review job piled up
# `queued` and never ran. And on SIGINT the partial the Loop persisted never
# reached stdout because run! raised before the answer was printed.
RSpec.describe Rubino::CLI::ChatCommand do
  let(:db)       { test_database }
  let(:null_ui)  { Rubino::UI::Null.new }
  let(:fake_llm) { FakeLLMAdapter.new }

  # #358 — the post-turn BackgroundReviewJob (the single memory+skills review
  # fork) must actually RUN before a headless one-shot exits, not sit queued.
  # Auto-extract ON at interval 1 (so the review is enqueued every turn); the
  # review's own model turn is neutralized by stubbing the captured system
  # prompt to nil, so the job drains as a clean no-op without extra FakeLLM
  # scripting (the fork's behaviour itself is covered in background_review_job_spec).
  describe "draining post-turn jobs before a headless exit (#358)" do
    let(:config) do
      mem    = Rubino::Config::Defaults.to_hash["memory"].merge("auto_extract" => false)
      skills = Rubino::Config::Defaults.to_hash["skills"].merge("auto_distill" => true, "auto_distill_interval" => 1)
      jobs   = { "mode" => "inline", "max_attempts" => 3, "poll_interval" => 1, "retry_backoff_seconds" => 0 }
      test_configuration("memory" => mem, "skills" => skills, "jobs" => jobs)
    end

    # The memory backend load_memory drives (recall only; the write path is the
    # review fork, stubbed to a no-op here via the nil system prompt).
    let(:backend) do
      bk = instance_double(Rubino::Memory::Backends::Sqlite)
      allow(bk).to receive_messages(user_profile: nil, project_context: nil, retrieve: [])
      bk
    end

    before do
      allow(Rubino).to receive_messages(database: db, configuration: config)
      allow(Rubino::LLM::RubyLLMAdapter).to receive(:new).and_return(fake_llm)
      allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(true)
      allow(Rubino::Memory::Backends).to receive(:build).and_return(backend)
      # No captured system prompt ⇒ the review fork skips cleanly (no eviction
      # risk), so the job still DRAINS to completion without a model call.
      allow(Rubino::Context::PromptAssembler).to receive(:system_prompt_for).and_return(nil)
      Rubino.ui = null_ui
    end

    it "runs the BackgroundReviewJob to completion before exiting (nothing left queued)" do
      fake_llm.enqueue_text("Noted — I prefer tabs.")

      expect do
        described_class.new("query" => "remember I prefer tabs").execute
      rescue SystemExit => e
        raise "expected a clean exit-0 run, got status #{e.status}"
      end.to output(/prefer tabs/).to_stdout

      # The post-turn review actually RAN (pre-fix it sat queued forever).
      review_jobs = db.db[:jobs].where(type: "BackgroundReviewJob").all
      expect(review_jobs.size).to eq(1)
      expect(review_jobs.first[:status]).to eq("completed")
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
      # item 6: the interrupt-path ensure now finalizes the session.
      allow(runner).to receive(:end_session!)
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
