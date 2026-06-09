# frozen_string_literal: true

RSpec.describe Rubino::Agent::Runner do
  let(:db)      { test_database }
  let(:null_ui) { Rubino::UI::Null.new }

  let(:fake_lifecycle) do
    instance_double(Rubino::Interaction::Lifecycle, execute: "RESPONSE")
  end

  before do
    allow(Rubino).to receive(:database).and_return(db)
    allow(Rubino::Interaction::Lifecycle).to receive(:new).and_return(fake_lifecycle)
  end

  # -----------------------------------------------------------------------
  # session creation
  # -----------------------------------------------------------------------

  describe "session creation" do
    it "creates a new session when no session_id given" do
      runner = described_class.new(model_override: "gpt-4o", ui: null_ui)
      expect(runner.instance_variable_get(:@session)[:status]).to eq("active")
    end

    it "resumes session by full ID" do
      repo = Rubino::Session::Repository.new(db: db.db)
      session = repo.create(source: "test", model: "gpt-4o")

      runner = described_class.new(session_id: session[:id], model_override: "gpt-4o", ui: null_ui)
      expect(runner.instance_variable_get(:@session)[:id]).to eq(session[:id])
    end

    it "resumes session by ID prefix" do
      repo = Rubino::Session::Repository.new(db: db.db)
      session = repo.create(source: "test", model: "gpt-4o")

      runner = described_class.new(session_id: session[:id][0..7], model_override: "gpt-4o", ui: null_ui)
      expect(runner.instance_variable_get(:@session)[:id]).to eq(session[:id])
    end

    it "resumes session by title partial match" do
      repo = Rubino::Session::Repository.new(db: db.db)
      session = repo.create(source: "test", model: "gpt-4o")
      repo.update(session[:id], title: "my refactoring session")

      runner = described_class.new(session_id: "refactoring", model_override: "gpt-4o", ui: null_ui)
      expect(runner.instance_variable_get(:@session)[:id]).to eq(session[:id])
    end

    it "raises SessionError for unknown session ID" do
      expect do
        described_class.new(session_id: "nonexistent-0000-0000", model_override: "gpt-4o", ui: null_ui)
      end.to raise_error(Rubino::SessionError)
    end

    it "stores provider override in session" do
      runner = described_class.new(model_override: "gpt-4o", provider_override: "anthropic", ui: null_ui)
      expect(runner.instance_variable_get(:@session)[:provider]).to eq("anthropic")
    end
  end

  # -----------------------------------------------------------------------
  # model_id
  # -----------------------------------------------------------------------

  describe "model_id" do
    it "uses model_override when provided" do
      runner = described_class.new(model_override: "claude-3-5-sonnet-20241022", ui: null_ui)
      expect(runner.instance_variable_get(:@model_id)).to eq("claude-3-5-sonnet-20241022")
    end

    it "falls back to config default when no override" do
      runner = described_class.new(ui: null_ui)
      expect(runner.instance_variable_get(:@model_id)).to eq(Rubino.configuration.model_default)
    end
  end

  # -----------------------------------------------------------------------
  # run
  # -----------------------------------------------------------------------

  describe "#run" do
    let(:runner) { described_class.new(model_override: "gpt-4o", ui: null_ui) }

    it "executes lifecycle and returns response" do
      expect(runner.run("hello")).to eq("RESPONSE")
    end

    it "passes ignore_rules to lifecycle" do
      runner = described_class.new(model_override: "gpt-4o", ignore_rules: true, ui: null_ui)
      runner.run("hello")
      expect(Rubino::Interaction::Lifecycle).to have_received(:new).with(
        hash_including(ignore_rules: true)
      )
    end

    # #141: --max-turns must reach the iteration budget. Runner threads it into
    # Lifecycle as max_tool_iterations (Lifecycle then forwards to IterationBudget).
    it "passes max_turns to lifecycle as max_tool_iterations" do
      runner = described_class.new(model_override: "gpt-4o", max_turns: 3, ui: null_ui)
      runner.run("hello")
      expect(Rubino::Interaction::Lifecycle).to have_received(:new).with(
        hash_including(max_tool_iterations: 3)
      )
    end

    it "returns nil and logs error on exception" do
      allow(fake_lifecycle).to receive(:execute).and_raise(StandardError, "boom")
      result = runner.run("hello")
      expect(result).to be_nil
      expect(null_ui.messages.any? { |m| m[:level] == :error }).to be true
    end

    # Regression: Runner.run used to re-emit INTERACTION_FAILED here even
    # though Lifecycle had already emitted it before re-raising. That gave
    # the SSE stream two `run.failed` frames for the same failure (visible
    # in the persisted events table). Lifecycle owns that signal now.
    it "does NOT re-emit INTERACTION_FAILED on lifecycle errors" do
      bus = Rubino.event_bus
      allow(fake_lifecycle).to receive(:execute).and_raise(StandardError, "provider down")
      emitted = []
      bus.on(Rubino::Interaction::Events::INTERACTION_FAILED) { |payload| emitted << payload }

      runner.run("hello")
      expect(emitted).to be_empty
    end
  end

  describe "#run!" do
    let(:runner) { described_class.new(model_override: "gpt-4o", ui: null_ui) }

    it "propagates lifecycle exceptions to the caller" do
      allow(fake_lifecycle).to receive(:execute).and_raise(StandardError, "boom")
      expect { runner.run!("hello") }.to raise_error(StandardError, "boom")
    end

    it "returns the lifecycle response on success" do
      expect(runner.run!("hello")).to eq("RESPONSE")
    end
  end

  # -----------------------------------------------------------------------
  # #144: opening chat must not persist an empty session. The Runner builds an
  # UNSAVED session; the row only appears once a message is committed.
  # -----------------------------------------------------------------------
  describe "lazy session creation (#144)" do
    let(:repo) { Rubino::Session::Repository.new(db: db.db) }

    it "does NOT persist a session row when no message is sent" do
      runner = described_class.new(model_override: "gpt-4o", ui: null_ui)
      id = runner.instance_variable_get(:@session)[:id]
      expect(repo.persisted?(id)).to be(false)
      expect(repo.list).to be_empty
    end

    it "end_session! on an unsent session leaves no row behind" do
      runner = described_class.new(model_override: "gpt-4o", ui: null_ui)
      id = runner.instance_variable_get(:@session)[:id]
      runner.end_session!
      expect(repo.persisted?(id)).to be(false)
      expect(repo.list).to be_empty
    end

    it "marks a resumed session as already persisted" do
      session = repo.create(source: "test", model: "gpt-4o")
      runner = described_class.new(session_id: session[:id], model_override: "gpt-4o", ui: null_ui)
      expect(runner.instance_variable_get(:@session)[:persisted]).to be(true)
    end
  end

  # -----------------------------------------------------------------------
  # B1: a cancelled turn must not poison subsequent turns.
  #
  # Regression: run! used to reuse the existing cancel token unless it was
  # *already* cancelled — an inverted guard that kept a cancelled (one-shot)
  # token forever, so every turn after the first Ctrl+C aborted instantly
  # with "interrupted by user". Each turn must start with a FRESH token.
  # -----------------------------------------------------------------------
  describe "cancel-token recovery (B1)" do
    let(:runner) { described_class.new(model_override: "gpt-4o", ui: null_ui) }

    it "runs a normal turn after an interrupt is handled" do
      # First turn: simulate an in-flight cancel that aborts the turn.
      allow(fake_lifecycle).to receive(:execute) do
        runner.cancel!
        raise Rubino::Interrupted
      end
      # The interrupt now commits the standardized `⎿ interrupted` marker via
      # the UI (replacing the old "interrupted by user" warning); assert the UI
      # was asked to render it and the turn returns nil.
      expect(null_ui).to receive(:turn_interrupted)
      expect(runner.run("interrupt me")).to be_nil

      # Second turn: lifecycle succeeds normally — must NOT be pre-cancelled.
      allow(fake_lifecycle).to receive(:execute).and_return("RESPONSE")
      expect(runner.run("now work")).to eq("RESPONSE")
    end

    it "gives each turn a distinct, non-cancelled token" do
      tokens = []
      allow(Rubino::Interaction::Lifecycle).to receive(:new) do |**kwargs|
        tokens << kwargs[:cancel_token]
        fake_lifecycle
      end

      runner.run!("one")
      first = tokens.last
      first.cancel!

      runner.run!("two")
      second = tokens.last

      expect(second).not_to equal(first)
      expect(second.cancelled?).to be false
    end
  end
end
