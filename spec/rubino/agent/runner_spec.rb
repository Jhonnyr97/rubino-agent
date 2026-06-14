# frozen_string_literal: true

RSpec.describe Rubino::Agent::Runner do
  let(:db)      { test_database }
  let(:null_ui) { Rubino::UI::Null.new }

  let(:fake_lifecycle) do
    instance_double(Rubino::Interaction::Lifecycle, execute: "RESPONSE")
  end

  # Holds the session the Lifecycle reports active AFTER a turn. Defaults to the
  # session the Lifecycle was built on (a non-compacting turn changes nothing);
  # a test exercising the P3 F1 compaction swap sets this to the child.
  let(:lifecycle_active_session) { {} }

  before do
    allow(Rubino).to receive(:database).and_return(db)
    allow(fake_lifecycle).to receive(:active_session) do
      lifecycle_active_session[:override] || lifecycle_active_session[:built_on]
    end
    allow(Rubino::Interaction::Lifecycle).to receive(:new) do |**kwargs|
      lifecycle_active_session[:built_on] = kwargs[:session]
      fake_lifecycle
    end
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

    # P3 F1: when an automatic budget-triggered compaction fires mid-turn, the
    # Lifecycle swaps its active session to the compaction child. The Runner
    # MUST adopt that child so the NEXT turn rebuilds Lifecycle on the SMALL
    # child instead of the un-shrunk parent (which would re-compact every turn
    # → superlinear DB/context bloat + ~2.9x slowdown). Fails on pre-fix code,
    # where @session stayed pinned to the parent across turns.
    it "adopts the compaction child as its active session after an auto-compaction turn" do
      parent_id = runner.session[:id]
      lifecycle_active_session[:override] = { id: "child-after-compaction", model: "gpt-4o", status: "active" }

      runner.run("a turn that crosses the compaction threshold")

      expect(runner.session[:id]).to eq("child-after-compaction")
      expect(runner.session[:id]).not_to eq(parent_id)
    end

    it "keeps the same active session across a turn with no compaction" do
      before_id = runner.session[:id]
      runner.run("an ordinary turn")
      expect(runner.session[:id]).to eq(before_id)
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

  # -----------------------------------------------------------------------
  # live model switch (/model)
  # -----------------------------------------------------------------------
  describe "#switch_model!" do
    let(:repo) { Rubino::Session::Repository.new(db: db.db) }

    it "retargets model_id, the session hash, and the persisted row" do
      session = repo.create(source: "cli", model: "gpt-4o", provider: "openai")
      runner = described_class.new(session_id: session[:id], model_override: "gpt-4o", ui: null_ui)

      runner.switch_model!("claude-sonnet-4-5")

      expect(runner.model_id).to eq("claude-sonnet-4-5")
      expect(runner.session[:model]).to eq("claude-sonnet-4-5")
      expect(repo.find(session[:id])[:model]).to eq("claude-sonnet-4-5")
      expect(repo.find(session[:id])[:provider]).to eq("anthropic")
    end

    it "makes the NEXT turn's lifecycle use the new model (override beats session)" do
      allow(Rubino::Interaction::Lifecycle).to receive(:new).and_return(fake_lifecycle)
      runner = described_class.new(model_override: "gpt-4o", ui: null_ui)
      runner.switch_model!("claude-sonnet-4-5")

      runner.run!("hello")

      expect(Rubino::Interaction::Lifecycle)
        .to have_received(:new).with(hash_including(model_override: "claude-sonnet-4-5"))
    end

    it "leaves an unpersisted lazy session consistent (no phantom row)" do
      runner = described_class.new(model_override: "gpt-4o", ui: null_ui)
      runner.switch_model!("gpt-5.2")

      expect(runner.session[:model]).to eq("gpt-5.2")
      expect(repo.persisted?(runner.session[:id])).to be false
    end
  end

  # Primary-agent switching (#320): the sticky `agent_definition=` and the
  # one-shot #run_with_agent both thread the agent's Definition into the
  # per-turn Lifecycle (where the system prompt + tool scope are applied).
  describe "agent switching" do
    let(:plan)    { Rubino.agent_registry.find("plan") }
    let(:explore) { Rubino.agent_registry.find("explore") }

    def last_agent_definition
      built = nil
      allow(Rubino::Interaction::Lifecycle).to receive(:new) do |**kwargs|
        built = kwargs[:agent_definition]
        lifecycle_active_session[:built_on] = kwargs[:session]
        fake_lifecycle
      end
      yield
      built
    end

    it "threads the sticky agent_definition into the Lifecycle" do
      runner = described_class.new(model_override: "gpt-4o", ui: null_ui)
      runner.agent_definition = plan
      definition = last_agent_definition { runner.run("hi") }
      expect(definition).to eq(plan)
    end

    it "uses the one-shot agent for #run_with_agent and restores the sticky" do
      runner = described_class.new(model_override: "gpt-4o", ui: null_ui)
      runner.agent_definition = plan

      definition = last_agent_definition { runner.run_with_agent(explore, "go") }
      expect(definition).to eq(explore)
      # the sticky pin is back after the one-shot turn
      expect(runner.agent_definition).to eq(plan)
    end
  end
end
