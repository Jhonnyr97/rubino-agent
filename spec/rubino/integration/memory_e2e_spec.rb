# frozen_string_literal: true

# End-to-end memory integration tests: Runner → Lifecycle → BackgroundReviewJob →
# MemoryTool → Backend → PromptAssembler injection.
#
# These tests use FakeLLMAdapter to script both the main-turn and the
# review-turn LLM responses without hitting any real API. The goal is to
# verify the full UNIFIED memory pipeline:
#   user input → turn complete → enqueue_post_turn_jobs → BackgroundReviewJob
#   (mid-session interval trigger) / flush_memory_on_session_end! (session-end
#   catch-all) → memory tool call → fact stored → listable via backend/CLI →
#   retrieved + injected into next session's system prompt.
#
# Memory and skills now ride the SAME unified warm-prefix review fork — the
# BackgroundReviewJob is the SINGLE extraction mechanism for both surfaces.
# The old inline Memory::Sync daemon path has been deleted.
#
# IMPORTANT: the BackgroundReviewJob runs on the detached POLISHING worker
# thread (not inline). After runner.run, join the polishing worker before
# asserting on the memory backend.
#
# The review fork's agent loop calls the LLM twice: once to get the tool call,
# then again with the tool result. Script BOTH calls to avoid "queue exhausted"
# retries on the follow-up.
RSpec.describe "Memory pipeline end-to-end with FakeLLMAdapter" do
  let(:db)        { test_database }
  let(:null_ui)   { Rubino::UI::Null.new }
  let(:fake_llm)  { FakeLLMAdapter.new }

  # auto_extract_interval=1 so the mid-session trigger fires on the FIRST turn
  # (deterministic). In production the default is 10.
  let(:config) do
    mem = Rubino::Config::Defaults.dig("memory").merge(
      "auto_extract" => true,
      "auto_extract_interval" => 1
    )
    skills = Rubino::Config::Defaults.dig("skills").merge("auto_distill" => false)
    test_configuration("memory" => mem, "skills" => skills)
  end

  before do
    allow(Rubino).to receive(:database).and_return(db)
    allow(Rubino).to receive(:ui).and_return(null_ui)
    allow(Rubino).to receive(:configuration).and_return(config)
    allow(Rubino).to receive(:event_bus).and_return(Rubino::Interaction::EventBus.new)
    allow(Rubino::LLM::RubyLLMAdapter).to receive(:new).and_return(fake_llm)

    # Ensure the memory tool is registered in the tool registry.
    Rubino::Tools::Registry.instance.reset!
    Rubino::Tools::Registry.instance.register(Rubino::Tools::MemoryTool.new)

    # Clear any facts left from previous examples (in-memory DB is shared).
    db.db[:memories].delete
  end

  def build_runner(**opts)
    Rubino::Agent::Runner.new(ui: null_ui, **opts)
  end

  # The BackgroundReviewJob runs on the detached polishing worker thread.
  # Join it so the review fork completes before assertions.
  def join_polishing(runner, timeout: 5)
    runner.instance_variable_get(:@polishing)&.wait(timeout)
  end

  # The review fork's agent loop calls the LLM at least twice: once for the
  # tool call, then again (with the tool result) to confirm or stop. Queue a
  # tool_call followed by a terminal text so both calls succeed.
  def enqueue_review_memory(content)
    fake_llm.enqueue_tool_call("memory", {
      "action" => "add",
      "target" => "user",
      "content" => content
    })
    fake_llm.enqueue_text("Memory saved.")
  end

  # ---------------------------------------------------------------------------
  # Core: write → list → inject (mid-session interval trigger)
  # ---------------------------------------------------------------------------

  describe "mid-session trigger → memory extraction → write → list → inject" do
    it "writes a memory fact via the unified BackgroundReviewJob and attributes it to the parent session" do
      # Main turn: user states a durable preference.
      fake_llm.enqueue_text("I'll remember that, Nilthon.")
      # Review turn (BackgroundReviewJob via polishing worker): emits a memory
      # tool call, then terminal text.
      enqueue_review_memory("User is named Nilthon and always uses mise")

      runner = build_runner
      result = runner.run("call me Nilthon; I always use mise")
      expect(result).to eq("I'll remember that, Nilthon.")

      parent_id = runner.session[:id]

      # Join the polishing worker so the review fork completes.
      join_polishing(runner)

      # Assert (a): written — backend list returns the fact.
      backend = Rubino::Memory::Backends.build(config: config)
      facts = backend.list
      expect(facts.size).to be >= 1
      nilthon_fact = facts.find { |f| f[:content].to_s.include?("Nilthon") }
      expect(nilthon_fact).not_to be_nil
      expect(nilthon_fact[:kind]).to eq("user_profile")
      # CRITICAL: source_session_id must be the PARENT driving session, not the
      # disposable child review session.
      expect(nilthon_fact[:source_session_id]).to eq(parent_id)

      # Assert (b): CLI timeline — MemoryCommand#list surfaces it.
      cli = Rubino::CLI::MemoryCommand.new([], {}, {})
      allow(cli).to receive(:backend_store).and_return(backend)
      allow(cli).to receive(:guard_corrupt_database!)
      allow(Rubino).to receive(:ensure_database_ready!)
      allow(Rubino).to receive(:ui).and_return(null_ui)
      cli.list
      table_calls = null_ui.messages.select { |m| m[:level] == :table }
      expect(table_calls).not_to be_empty
      row_texts = table_calls.flat_map { |t| t[:message][:rows] }.flatten.map(&:to_s)
      expect(row_texts.any? { |r| r.include?("Nilthon") }).to be(true)
    end

    it "retrieves and injects the memory into a second session's prompt" do
      # First session: create a memory.
      fake_llm.enqueue_text("Got it.")
      enqueue_review_memory("User prefers terse responses")

      runner1 = build_runner
      runner1.run("I prefer terse responses")
      join_polishing(runner1)

      # Verify the memory is in the backend before the second session.
      backend = Rubino::Memory::Backends.build(config: config)
      expect(backend.count).to be >= 1
      expect(backend.user_profile).to include("terse responses")

      # Reset the frozen snapshot so PromptAssembler captures fresh memory
      # state for the next session.
      Rubino::Context::PromptAssembler.reset_all_snapshots!

      # Second session: the memory should appear in the system prompt.
      fake_llm.enqueue_text("Understood, keeping it short.")
      runner2 = build_runner
      runner2.run("hello again")

      # The last LLM call is the second session's main turn —
      # its system prompt should contain [User Profile].
      turn2_call = fake_llm.calls.last
      system_msg = turn2_call[:messages].find { |m| m[:role] == "system" }
      expect(system_msg).not_to be_nil
      expect(system_msg[:content]).to include("[User Profile]")
      expect(system_msg[:content]).to include("terse responses")
    end
  end

  # ---------------------------------------------------------------------------
  # Regression guard: session-end catch-all with high interval
  # ---------------------------------------------------------------------------

  describe "session-end memory flush (regression guard)" do
    it "mines memory at session end when interval would skip mid-session extraction" do
      # Use interval=100 so the mid-session interval gate (interval_due?) skips
      # turn 1 (1 % 100 != 0). The session-end flush is the catch-all. We prove
      # a short session still gets its facts mined at teardown.
      deep_throttled = test_configuration(
        "memory" => Rubino::Config::Defaults.dig("memory").merge(
          "auto_extract" => true,
          "auto_extract_interval" => 100
        ),
        "skills" => { "auto_distill" => false }
      )
      allow(Rubino).to receive(:configuration).and_return(deep_throttled)

      # Main turn: enqueue a text response.
      fake_llm.enqueue_text("Turn 1 done.")

      runner = build_runner
      runner.run("turn one: I use vim")

      # Verify NO memory was created yet (mid-session interval gate skipped).
      backend = Rubino::Memory::Backends.build(config: deep_throttled)
      expect(backend.count).to eq(0)

      # Now end the session — this triggers flush_memory_on_session_end! which
      # performs BackgroundReviewJob with surfaces=["memory"] inline (the
      # session-end path calls `perform` directly, not through the queue, for
      # non-interactive runners). Script both the tool call AND the follow-up
      # terminal text so the review fork's agent loop completes cleanly.
      enqueue_review_memory("User uses vim and prefers dark themes")
      runner.end_session!

      # Memory should now exist from the session-end flush.
      expect(backend.count).to eq(1)
      fact = backend.list.first
      expect(fact[:content]).to include("vim")
    end
  end

  # ---------------------------------------------------------------------------
  # Combined surface: when both skill and memory are configured, the mid-session
  # trigger includes both surfaces in one job.
  # ---------------------------------------------------------------------------

  describe "combined surface (skill + memory due same turn)" do
    let(:combined_config) do
      mem = Rubino::Config::Defaults.dig("memory").merge(
        "auto_extract" => true,
        "auto_extract_interval" => 1
      )
      skills = Rubino::Config::Defaults.dig("skills").merge(
        "enabled" => true,
        "auto_distill" => true,
        "auto_distill_interval" => 1
      )
      test_configuration("memory" => mem, "skills" => skills)
    end

    before do
      allow(Rubino).to receive(:configuration).and_return(combined_config)
      Rubino::Tools::Registry.instance.register(Rubino::Skills::SkillTool.new)
      db.db[:memories].delete
    end

    it "extracts memory when both surfaces are due (combined prompt)" do
      # Main turn.
      fake_llm.enqueue_text("Main turn done.")
      # Review turn (COMBINED_REVIEW_PROMPT): emits a memory tool call first,
      # then terminal text (skill tool not emitted — this is a minimal test).
      fake_llm.enqueue_tool_call("memory", {
        "action" => "add",
        "target" => "user",
        "content" => "User is named Nilthon"
      })
      fake_llm.enqueue_text("Nothing to save for skills.")

      runner = build_runner
      result = runner.run("my name is Nilthon and I like testing")
      expect(result).to eq("Main turn done.")
      join_polishing(runner)

      # Memory should exist.
      backend = Rubino::Memory::Backends.build(config: combined_config)
      expect(backend.count).to be >= 1
      fact = backend.list.find { |f| f[:content].to_s.include?("Nilthon") }
      expect(fact).not_to be_nil
    end
  end
end
