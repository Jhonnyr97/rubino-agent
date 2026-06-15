# frozen_string_literal: true

require "stringio"

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

  def capture_stderr
    orig = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = orig
  end

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
  # #347: explicit `--resume <id>` owner-guard. Auto-resume already skips a
  # session a DIFFERENT live process is writing; explicit resume had no guard,
  # so N processes latched the same active row and interleaved writes into one
  # malformed transcript. The Runner must fork a child (with copied history)
  # when the target is live-owned by another process, and claim ownership when
  # it isn't — so two concurrent explicit resumes never write to one row.
  # -----------------------------------------------------------------------
  describe "explicit-resume owner-guard (#347)" do
    let(:repo)  { Rubino::Session::Repository.new(db: db.db) }
    let(:store) { Rubino::Session::Store.new(db: db.db) }

    # The Runner builds its own Session::Repository internally. Inject a real
    # repo (on the test DB) whose atomic-claim verdict we can pin per-example —
    # cleaner than stubbing the private liveness probe on any instance. Resume
    # now claims ATOMICALLY (#390): the Runner forks iff claim_for_resume! loses
    # the race (returns false), so pin THAT to drive the fork-vs-claim branch.
    def inject_repo(owned_by_other:)
      injected = Rubino::Session::Repository.new(db: db.db)
      allow(injected).to receive(:claim_for_resume!).and_return(!owned_by_other)
      allow(Rubino::Session::Repository).to receive(:new).and_return(injected)
      injected
    end

    def seed_session_with_history(owner_pid:)
      s = repo.create(source: "cli", model: "gpt-4o")
      store.create(session_id: s[:id], role: "user", content: "hello")
      store.create(session_id: s[:id], role: "assistant", content: "hi there")
      repo.update(s[:id], status: "active", owner_pid: owner_pid,
                          message_count: store.count(s[:id]))
      repo.find(s[:id])
    end

    it "forks a fresh child (copying history) when another LIVE process owns it" do
      parent = seed_session_with_history(owner_pid: 999_999)
      inject_repo(owned_by_other: true)

      runner = described_class.new(session_id: parent[:id], model_override: "gpt-4o", ui: null_ui)
      child = runner.session

      # A SEPARATE row, lineage back to the parent, the FULL history copied.
      expect(child[:id]).not_to eq(parent[:id])
      expect(child[:parent_session_id]).to eq(parent[:id])
      expect(store.count(child[:id])).to eq(2)
      # The live parent is left untouched (the other process still owns it).
      expect(repo.find(parent[:id])[:owner_pid]).to eq(999_999)
    end

    # #420: a HEADLESS `--resume` that LOSES the race silently re-routed to a
    # fork with no signal (the status line is gated on @announce_session, off
    # headless). Emit a one-line STDERR notice even headless so a pipeline can
    # tell its resume was re-routed to a different session.
    it "warns on STDERR when a headless (announce_session:false) resume forks (#420)" do
      parent = seed_session_with_history(owner_pid: 999_999)
      inject_repo(owned_by_other: true)

      out = capture_stderr do
        runner = described_class.new(session_id: parent[:id], model_override: "gpt-4o",
                                     ui: null_ui, announce_session: false)
        expect(runner.session[:id]).not_to eq(parent[:id]) # it forked
      end
      expect(out).to include("is in use by another rubino — forked a copy")
    end

    it "claims (does not fork) a session NOT owned by another live process" do
      parent = seed_session_with_history(owner_pid: nil)
      # Drive the REAL atomic claim (no stub): an unowned row is claimed and the
      # owner_pid stamped to THIS process in a single CAS.

      runner = described_class.new(session_id: parent[:id], model_override: "gpt-4o", ui: null_ui)
      expect(runner.session[:id]).to eq(parent[:id])
      # Claimed for THIS process so a later concurrent resume forks, not stomps.
      expect(repo.find(parent[:id])[:owner_pid]).to eq(Process.pid)
    end

    # Two concurrent explicit resumes of the SAME session must not interleave
    # into one malformed transcript: the first claims it, the second sees a live
    # owner and forks. Drives the REAL predicate (no stub) — the first resume's
    # claim flips the verdict the second resume reads.
    it "does not interleave concurrent explicit resumes (first claims, second forks)" do
      parent = seed_session_with_history(owner_pid: nil)

      first = described_class.new(session_id: parent[:id], model_override: "gpt-4o", ui: null_ui)
      expect(first.session[:id]).to eq(parent[:id])
      claimed = repo.find(parent[:id])
      expect(claimed[:owner_pid]).to eq(Process.pid)

      # Now the row is owned by a live process (us). A second resumer is a
      # DIFFERENT process that LOSES the atomic claim; simulate that by making
      # claim_for_resume! return false for the claimed row, and assert it forks
      # rather than latching onto the same row.
      injected = Rubino::Session::Repository.new(db: db.db)
      allow(injected).to receive(:claim_for_resume!) do |row|
        row[:id] != parent[:id] # loses the race for the already-claimed parent
      end
      allow(Rubino::Session::Repository).to receive(:new).and_return(injected)

      second = described_class.new(session_id: parent[:id], model_override: "gpt-4o", ui: null_ui)
      expect(second.session[:id]).not_to eq(parent[:id])
      expect(second.session[:parent_session_id]).to eq(parent[:id])
      # The two runners write to DISTINCT rows → no interleaved transcript.
      expect(first.session[:id]).not_to eq(second.session[:id])
    end

    # #376 (residual #347): the owner-guard used to fire ONLY on status="active",
    # so two concurrent explicit resumes of an ENDED session raced unguarded and
    # interleaved writes into one malformed transcript (user,user …). A finished
    # turn leaves status="ended"; the first resumer still claims owner_pid without
    # flipping status back to active. This drives the Runner through the REAL,
    # status-blind predicate (no stub on owned_by_other_live_process?): we only
    # pin the liveness probe so the claimed pid reads as a live OTHER process. On
    # pre-fix code the predicate returned false for the ended row, the second
    # resumer latched onto the same row, and these forks expectations failed.
    it "does not interleave concurrent explicit resumes of an ENDED session (#376)" do
      parent = seed_session_with_history(owner_pid: nil)
      repo.end_session!(parent[:id]) # status -> "ended", owner_pid -> nil

      first = described_class.new(session_id: parent[:id], model_override: "gpt-4o", ui: null_ui)
      expect(first.session[:id]).to eq(parent[:id])
      claimed = repo.find(parent[:id])
      # Claimed by THIS live process, but the row is STILL "ended" (resume does
      # not flip status); the pre-fix guard ignored it purely on that basis.
      expect(claimed[:owner_pid]).to eq(Process.pid)
      expect(claimed[:status]).to eq("ended")

      # A second, DIFFERENT live process resumes the same ended row. Build a real
      # repo on the test DB; pretend the claimed owner_pid belongs to a live
      # process that ISN'T us by reporting OUR pid as a foreign live pid. The REAL
      # status-blind predicate then returns true and the Runner must fork.
      injected = Rubino::Session::Repository.new(db: db.db)
      foreign_pid = Process.pid + 1
      allow(injected).to receive(:process_alive?).and_call_original
      allow(injected).to receive(:process_alive?).with(foreign_pid).and_return(true)
      repo.update(parent[:id], owner_pid: foreign_pid) # someone else now holds it
      allow(Rubino::Session::Repository).to receive(:new).and_return(injected)

      second = described_class.new(session_id: parent[:id], model_override: "gpt-4o", ui: null_ui)
      expect(second.session[:id]).not_to eq(parent[:id])
      expect(second.session[:parent_session_id]).to eq(parent[:id])
      expect(first.session[:id]).not_to eq(second.session[:id])
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
  # detached post-turn polishing (#319)
  # -----------------------------------------------------------------------
  describe "#cancel! extends to the detached polishing" do
    let(:runner) { described_class.new(model_override: "gpt-4o", ui: null_ui) }

    it "passes the runner-owned polishing worker into the lifecycle" do
      runner.run!("hi")
      expect(Rubino::Interaction::Lifecycle)
        .to have_received(:new).with(hash_including(polishing: runner.polishing))
    end

    it "ONE Esc cancels BOTH the foreground turn AND the background polishing" do
      expect(runner.polishing).to receive(:cancel!)
      runner.cancel!
    end

    it "#polishing? reflects the detached worker's liveness" do
      allow(runner.polishing).to receive(:running?).and_return(true)
      expect(runner.polishing?).to be(true)
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
