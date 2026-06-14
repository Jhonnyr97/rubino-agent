# frozen_string_literal: true

RSpec.describe Rubino::Interaction::Lifecycle do
  # persist_user_message only collaborates with @message_store / @session_repo,
  # so config is unused here.
  subject(:lifecycle) do
    described_class.new(
      session: session,
      event_bus: event_bus,
      ui: null_ui,
      config: nil
    )
  end

  let(:session)   { { id: "sess-1", model: "gpt-4o" } }
  let(:event_bus) { Rubino::Interaction::EventBus.new }
  let(:null_ui)   { Rubino::UI::Null.new }

  describe "#persist_user_message" do
    let(:message_store) do
      instance_double(Rubino::Session::Store, create: nil)
    end
    let(:session_repo) do
      instance_double(Rubino::Session::Repository,
                      increment_message_count!: nil, update: nil, persist!: session)
    end

    before do
      lifecycle.instance_variable_set(:@message_store, message_store)
      lifecycle.instance_variable_set(:@session_repo, session_repo)
    end

    # #144: the session row is inserted lazily on the first message, so opening
    # chat and leaving without typing never persists an empty row.
    it "lazily persists the session before storing the first message" do
      expect(session_repo).to receive(:persist!).with(session).ordered
      expect(message_store).to receive(:create).ordered

      lifecycle.send(:persist_user_message, "hello")
    end

    it "persists plain text verbatim" do
      expect(message_store).to receive(:create).with(
        session_id: "sess-1", role: "user", content: "hello there"
      )

      lifecycle.send(:persist_user_message, "hello there")
    end

    # Audit finding (1): image attaching is owned by the image_paths pipeline,
    # not by stripping paths out of the message text. A user who types a path
    # must have that path preserved in the stored/sent message.
    it "keeps an image-path-looking token in the persisted text" do
      input = "please look at ./diagram.png and explain it"

      expect(message_store).to receive(:create).with(
        session_id: "sess-1", role: "user", content: input
      )

      lifecycle.send(:persist_user_message, input)
    end

    it "increments the session message count" do
      expect(session_repo).to receive(:increment_message_count!).with("sess-1")

      lifecycle.send(:persist_user_message, "hi")
    end

    # #103: the first user message auto-titles a still-untitled session so
    # /sessions is navigable and --resume <title> can match.
    it "auto-titles an untitled session from the first user message" do
      expect(session_repo).to receive(:update).with("sess-1", title: "Add a modulo operation")

      lifecycle.send(:persist_user_message, "Add a modulo operation")
      expect(session[:title]).to eq("Add a modulo operation")
    end

    it "does not retitle a session that already has a title" do
      session[:title] = "existing title"
      expect(session_repo).not_to receive(:update)

      lifecycle.send(:persist_user_message, "a brand new message")
      expect(session[:title]).to eq("existing title")
    end

    it "leaves a blank-input session untitled rather than storing an empty title" do
      expect(session_repo).not_to receive(:update)

      lifecycle.send(:persist_user_message, "   ")
    end
  end

  # F1 (P3 endurance): automatic budget-triggered compaction MUST swap the
  # active session to the compaction child, exactly as the manual /compact path
  # does (chat_command.rb: result[:compact_into] → build_runner on the child).
  # Before the fix, #check_and_compact called Compressor#compact! but never
  # reassigned @session, so every subsequent turn persisted back to the dead
  # parent, the parent never shrank, needs_compaction? stayed permanently true,
  # and the gem re-compacted on EVERY turn (superlinear DB/context bloat + the
  # ~2.9x per-turn slowdown). These specs fail on the pre-fix code.
  describe "#check_and_compact" do
    subject(:lifecycle) do
      described_class.new(
        session: parent_session, event_bus: event_bus, ui: null_ui, config: nil
      )
    end

    let(:parent_session) { { id: "parent-1", model: "gpt-4o" } }
    let(:child_session)  { { id: "child-9",  model: "gpt-4o" } }
    let(:long_messages)  { Array.new(10) { { role: "user", content: "x" } } }
    let(:budget) { instance_double(Rubino::Context::TokenBudget) }
    let(:compressor) { instance_double(Rubino::Context::Compressor) }
    let(:session_repo) { instance_double(Rubino::Session::Repository) }
    let(:assembler) { instance_double(Rubino::Context::PromptAssembler, build: %i[compacted]) }

    before do
      allow(Rubino::Context::TokenBudget).to receive(:new).and_return(budget)
      allow(Rubino::Context::Compressor).to receive(:new).and_return(compressor)
      allow(Rubino::Context::PromptAssembler).to receive(:new).and_return(assembler)
      lifecycle.instance_variable_set(:@session_repo, session_repo)
      allow(session_repo).to receive(:find).with("child-9").and_return(child_session)
    end

    it "reassigns the active session to the compaction child after compact!" do
      allow(budget).to receive(:needs_compaction?).and_return(true)
      allow(compressor).to receive(:compact!).and_return(
        source_session_id: "parent-1", target_session_id: "child-9",
        original_messages: 10, compacted_messages: 5, saved_tokens: 12, summary_id: "sum-1"
      )

      lifecycle.send(:check_and_compact, long_messages)

      # The fix: subsequent phases (run_agent_loop, update_session_state,
      # enqueue_post_turn_jobs) must now bind to the SMALL child, not the parent.
      active = lifecycle.instance_variable_get(:@session)
      expect(active[:id]).to eq("child-9")
    end

    it "rebuilds the prompt from the child session, not the dead parent" do
      allow(budget).to receive(:needs_compaction?).and_return(true)
      allow(compressor).to receive(:compact!).and_return(
        source_session_id: "parent-1", target_session_id: "child-9"
      )

      lifecycle.send(:check_and_compact, long_messages)

      # The post-compaction assembler must read the child session so the turn
      # runs on the compacted context — not the dead parent.
      expect(Rubino::Context::PromptAssembler).to have_received(:new)
        .with(hash_including(session: child_session))
    end

    it "leaves the active session untouched when no compaction is needed" do
      allow(budget).to receive(:needs_compaction?).and_return(false)
      expect(compressor).not_to receive(:compact!)

      result = lifecycle.send(:check_and_compact, long_messages)

      expect(result).to eq(long_messages)
      expect(lifecycle.instance_variable_get(:@session)[:id]).to eq("parent-1")
    end

    # A no-op compaction (too few messages / empty middle) creates no child and
    # returns no target_session_id — the parent must stay active in that case.
    it "keeps the parent active when compaction is a no-op (no child created)" do
      allow(budget).to receive(:needs_compaction?).and_return(true)
      allow(compressor).to receive(:compact!).and_return(
        source_session_id: "parent-1", saved_tokens: 0, skipped: true
      )

      lifecycle.send(:check_and_compact, long_messages)

      expect(lifecycle.instance_variable_get(:@session)[:id]).to eq("parent-1")
    end
  end

  describe "#load_memory" do
    subject(:lifecycle) do
      described_class.new(
        session: session,
        event_bus: event_bus,
        ui: null_ui,
        config: test_configuration("memory" => { "enabled" => true })
      )
    end

    it "routes recall through the configured memory backend, passing the query" do
      backend = instance_double(
        Rubino::Memory::Backends::Default,
        user_profile: "UP", project_context: "PC", retrieve: %i[m1]
      )
      allow(Rubino::Memory::Backends).to receive(:build).and_return(backend)
      expect(backend).to receive(:retrieve).with(session_id: "sess-1", query: "hello")

      result = lifecycle.send(:load_memory, "hello")
      expect(result).to eq(user_profile: "UP", project_context: "PC", relevant_memories: %i[m1])
    end

    it "returns an empty hash when memory is disabled" do
      disabled = described_class.new(
        session: session, event_bus: event_bus, ui: null_ui,
        config: test_configuration("memory" => { "enabled" => false })
      )
      expect(Rubino::Memory::Backends).not_to receive(:build)
      expect(disabled.send(:load_memory, "hi")).to eq({})
    end
  end

  # The terminal run.completed event (INTERACTION_FINISHED) must carry the final
  # assistant text in its `output` regardless of streaming mode. On the
  # non-streaming path NO message.delta chunks are emitted, so this is the only
  # place a client can read the answer — without it a completed run terminates
  # empty. Recorder maps the payload straight onto the persisted run.completed.
  describe "#execute final output contract" do
    before do
      # Stub every phase except the terminal emit so we can drive #execute
      # without a live model/store. The agent loop returns the final text the
      # same way the real Loop returns response.content.
      allow(lifecycle).to receive(:persist_user_message)
      allow(lifecycle).to receive(:load_memory).and_return({})
      allow(lifecycle).to receive(:build_messages).and_return([])
      allow(lifecycle).to receive(:load_tools).and_return([])
      allow(lifecycle).to receive(:check_and_compact) { |messages| messages }
      allow(lifecycle).to receive(:update_session_state)
      allow(lifecycle).to receive(:enqueue_post_turn_jobs)
    end

    it "emits run.completed carrying the final answer on the non-streaming path" do
      allow(lifecycle).to receive(:run_agent_loop).and_return("The answer is 42.")

      captured = nil
      event_bus.on(Rubino::Interaction::Events::INTERACTION_FINISHED) { |p| captured = p }

      result = lifecycle.execute("count something")

      expect(result).to eq("The answer is 42.")
      expect(captured).to eq(output: "The answer is 42.")
    end

    it "still carries the final answer on the streaming path" do
      allow(lifecycle).to receive(:run_agent_loop).and_return("Streamed answer.")

      captured = nil
      event_bus.on(Rubino::Interaction::Events::INTERACTION_FINISHED) { |p| captured = p }

      lifecycle.execute("ask")

      expect(captured).to eq(output: "Streamed answer.")
    end

    it "records the output onto the run.completed event via Recorder" do
      allow(lifecycle).to receive(:run_agent_loop).and_return("Persisted text.")

      store = instance_double(Rubino::Run::EventStore)
      recorder = Rubino::Run::Recorder.new(
        run_id: "run-1", session_id: "sess-1", event_bus: event_bus, store: store
      )
      recorder.attach!

      expect(store).to receive(:append).with(
        session_id: "sess-1", run_id: "run-1",
        type: "run.completed", payload: { output: "Persisted text." }
      )
      # Other lifecycle events flow through the same recorder; accept them.
      allow(store).to receive(:append)

      lifecycle.execute("go")
    ensure
      recorder.detach!
    end
  end

  # #319: the post-turn polishing must run DETACHED — it must NOT drain the aux
  # jobs synchronously inside the turn (which blocked the next prompt and, under
  # a 429 storm, stalled ~80s). With a polishing worker wired it only PERSISTS
  # the rows (drain_inline: false) and hands off to the detached worker.
  describe "#enqueue_post_turn_jobs detachment (#319)" do
    let(:db_connection) { test_database }
    let(:detach_config) do
      test_configuration(
        "jobs" => { "mode" => "inline", "max_attempts" => 3, "poll_interval" => 1,
                    "retry_backoff_seconds" => 0 },
        "memory" => { "enabled" => true, "auto_extract" => true },
        "skills" => { "auto_distill" => false }
      )
    end
    let(:polishing) { instance_spy(Rubino::Interaction::Polishing) }
    let(:lifecycle) do
      described_class.new(session: { id: "sess-1", model: "gpt-4o" },
                          event_bus: event_bus, ui: null_ui, config: detach_config,
                          polishing: polishing)
    end

    before do
      allow(Rubino).to receive(:database).and_return(db_connection)
      db_connection.db[:jobs].delete
      # Short-circuit the >20-messages summarize gate so only the memory-extract
      # row is enqueued (count is stubbed per-lifecycle on its message store).
      [lifecycle].each { |lc| stub_message_count(lc, 1) }
    end

    def stub_message_count(lifecycle, count)
      store = lifecycle.instance_variable_get(:@message_store)
      allow(store).to receive(:count).and_return(count)
    end

    it "does NOT drain the aux job inline (the next prompt is never blocked)" do
      # The blocking behavior on the old code path: enqueue → Jobs::Runner.new →
      # run_job, synchronously. With the detached worker wired this must NOT fire.
      expect(Rubino::Jobs::Runner).not_to receive(:new)

      lifecycle.send(:enqueue_post_turn_jobs)

      # The row is PERSISTED (queued), ready for the detached worker — not run.
      row = db_connection.db[:jobs].where(type: "ExtractMemoryJob").first
      expect(row[:status]).to eq("queued")
    end

    it "hands the drain off to the detached polishing worker" do
      lifecycle.send(:enqueue_post_turn_jobs)
      expect(polishing).to have_received(:start)
    end

    it "keeps the synchronous inline drain when NO polishing worker is wired" do
      no_worker = described_class.new(session: { id: "sess-2", model: "gpt-4o" },
                                      event_bus: event_bus, ui: null_ui, config: detach_config)
      stub_message_count(no_worker, 1)
      # API/server + subagent path: drain_inline stays true, so inline mode runs
      # the job synchronously exactly as before.
      expect(Rubino::Jobs::Runner).to receive(:new).at_least(:once).and_call_original
      no_worker.send(:enqueue_post_turn_jobs)
    end
  end
end
