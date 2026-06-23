# frozen_string_literal: true

# Loop-level integration of the fabricated-"done" guard (#r5 F1 / MF-3 / B1):
# a toolless turn whose prose claims an action it never carried out must NOT
# reach the user as a completed answer. The structured tool-call channel is the
# only thing that advances state; the guard reflects a corrective turn (capped)
# or, for a `cd` claim rubino can't honour, rewrites the answer honestly.
RSpec.describe Rubino::Agent::Loop do
  let(:db)            { test_database }
  let(:null_ui)       { Rubino::UI::Null.new }
  let(:event_bus)     { Rubino::Interaction::EventBus.new }
  let(:fake_llm)      { FakeLLMAdapter.new }
  let(:config)        { test_configuration }
  let(:message_store) { Rubino::Session::Store.new }
  let(:session) do
    Rubino::Session::Repository.new.create(source: "test", model: "fake-model")
  end
  let(:approval_policy) { Rubino::Security::ApprovalPolicy.new(config: config) }
  let(:tool_executor) do
    Rubino::Agent::ToolExecutor.new(
      registry: Rubino::Tools::Registry,
      approval_policy: approval_policy,
      ui: null_ui,
      config: config,
      event_bus: event_bus
    )
  end
  let(:budget) { Rubino::Agent::IterationBudget.new(config: config) }

  # A minimal "shell" stand-in so the guard sees shell/test/write exposed and the
  # tool actually runs when the model finally calls it.
  let(:tools) do
    %w[shell test write].map { |n| double("Tool", name: n) }
  end

  before do
    allow(Rubino).to receive(:database).and_return(db)
  end

  def build_loop
    Rubino::Agent::Loop.new(
      session: session,
      llm_adapter: fake_llm,
      tool_executor: tool_executor,
      message_store: message_store,
      budget: budget,
      ui: null_ui,
      event_bus: event_bus,
      config: config
    )
  end

  def user_messages(text = "run the tests")
    [{ role: "user", content: text }]
  end

  describe "narrate-without-acting (0 tools) is NOT surfaced as the final answer" do
    it "reflects, then accepts the REAL tool call the reflection forced" do
      # Turn 1: fabricated "Running the suite now." with no tool call.
      fake_llm.enqueue_text("Running the suite now.")
      # Turn 2 (post-reflection): the model now actually calls the shell tool.
      fake_llm.enqueue_tool_call("shell", { "command" => "pytest" })
      # Turn 3: honest summary AFTER a tool ran.
      fake_llm.enqueue_text("Tests passed: 10 passed.")

      # The shell tool exists in the registry; let it run trivially.
      allow(tool_executor).to receive(:execute).and_return(
        Rubino::Tools::Result.success(name: "shell", call_id: "c1", output: "10 passed")
      )

      result = build_loop.run(messages: user_messages, tools: tools)

      # The fabricated line never became the final answer; the real, post-tool
      # summary did.
      expect(result).to eq("Tests passed: 10 passed.")
      expect(result).not_to eq("Running the suite now.")
      # The corrective re-prompt was injected as a user message in the transcript.
      contents = message_store.for_session(session[:id]).map(&:content)
      expect(contents.join("\n")).to match(/issued NO tool call/i)
    end

    it "BINDS after the reflection cap — REPLACES the fabrication, never surfaces it (G1)" do
      # The model keeps narrating a git mutation without ever calling a tool.
      # After MAX_REFLECTIONS corrective turns the guard becomes BINDING: it
      # REPLACES the fabricated final answer with an honest deterministic message
      # rather than letting the hallucinated "committed as <sha>" reach the user.
      (Rubino::Agent::ActionClaimGuard::MAX_REFLECTIONS + 2).times do
        fake_llm.enqueue_text("Done. New branch feature/tax committed as 0f60f1d.")
      end

      result = build_loop.run(messages: user_messages("create a branch and move my changes"),
                              tools: tools)

      # Both reflection shapes count: the FIRST names the fabrication in full
      # ("issued NO tool call"); a later one DECAYS to the short atomic
      # instruction ("Still no tool call") so the heavy framing cannot compound
      # into a confession spiral (#353b).
      reflections = message_store.for_session(session[:id])
                                 .map(&:content)
                                 .count { |c| c.to_s.match?(/issued NO tool call|Still no tool call/i) }
      expect(reflections).to eq(Rubino::Agent::ActionClaimGuard::MAX_REFLECTIONS)
      # The fabricated SHA / "committed as" NEVER becomes the user-visible answer.
      expect(result).not_to include("0f60f1d")
      expect(result).not_to match(/committed as/i)
      # Instead the honest deterministic message is surfaced AND persisted.
      expect(result).to match(/no tool call was made/i)
      expect(result).to match(/nothing was changed on disk/i)
      stored = message_store.for_session(session[:id])
                            .select { |m| m.role == "assistant" }
                            .map(&:content)
      expect(stored.last).to match(/no tool call was made/i)
    end

    it "reflects a fabricated MUTATION 'Done. <file> now contains X' (r5c NEW-1)" do
      # 0-tool state-result fabrication, then the forced real write.
      fake_llm.enqueue_text('Done. /work/README.md now contains "API v2".')
      fake_llm.enqueue_tool_call("write", { "path" => "/work/README.md", "content" => "API v2" })
      fake_llm.enqueue_text("README.md updated to API v2.")

      allow(tool_executor).to receive(:execute).and_return(
        Rubino::Tools::Result.success(name: "write", call_id: "c1", output: "wrote 6 bytes")
      )

      result = build_loop.run(messages: user_messages("set README to API v2"), tools: tools)

      expect(result).to eq("README.md updated to API v2.")
      expect(result).not_to include("now contains")
      contents = message_store.for_session(session[:id]).map(&:content)
      expect(contents.join("\n")).to match(/issued NO tool call/i)
    end

    it "reflects a BUNDLED edit-claim + trailing intent on the EDIT (r5c B1)" do
      fake_llm.enqueue_text("Updated both methods to use item instead of it. Running the tests now.")
      fake_llm.enqueue_text("I did not actually edit the file — there was no tool call.")

      result = build_loop.run(messages: user_messages("rename it to item"), tools: tools)

      expect(result).to match(/did not actually edit/i)
      contents = message_store.for_session(session[:id]).map(&:content)
      expect(contents.join("\n")).to match(/issued NO tool call/i)
    end

    it "passes a genuine text answer straight through (no tool claim, no nag)" do
      fake_llm.enqueue_text("The mean of [1,2,3] is 2.")
      result = build_loop.run(messages: user_messages("what is the mean"), tools: tools)
      expect(result).to eq("The mean of [1,2,3] is 2.")
      contents = message_store.for_session(session[:id]).map(&:content)
      expect(contents.join("\n")).not_to match(/issued NO tool call/i)
    end
  end

  # #353a — the guard is context-aware end-to-end: a USER-requested no-action turn
  # (plan / answer-from-memory) is surfaced as-is, NOT challenged.
  describe "user-requested no-action turn is surfaced as-is (#353a)" do
    it "does NOT challenge a 'list the plan, don't implement' turn" do
      plan = "Here's the plan:\n1. I'll add a guard to parse().\n2. Then I'll run the tests."
      fake_llm.enqueue_text(plan)

      result = build_loop.run(
        messages: user_messages("Do not implement yet — just list the plan."),
        tools: tools
      )

      expect(result).to eq(plan)
      contents = message_store.for_session(session[:id]).map(&:content)
      expect(contents.join("\n")).not_to match(/issued NO tool call/i)
    end

    it "does NOT challenge 'answer from memory without using any tools'" do
      answer = "From memory: foo() validates input, then I'll write the result to disk."
      fake_llm.enqueue_text(answer)

      result = build_loop.run(
        messages: user_messages("Without using any tools, answer from memory: what does foo() do?"),
        tools: tools
      )

      expect(result).to eq(answer)
      contents = message_store.for_session(session[:id]).map(&:content)
      expect(contents.join("\n")).not_to match(/issued NO tool call/i)
    end
  end

  # #353b — the reflection that recovers a stuck model DECAYS to a short atomic
  # instruction on the 2nd injection instead of repeating the heavy challenge.
  describe "reflections are bounded + decay so they don't compound (#353b)" do
    it "injects the FULL challenge first, then a DECAYED atomic instruction" do
      # Two 0-tool fabrications in a row, then a real tool call recovers.
      fake_llm.enqueue_text("I ran the tests and they all pass.")
      fake_llm.enqueue_text("I ran the tests and they all pass.")
      fake_llm.enqueue_tool_call("test", {})
      fake_llm.enqueue_text("Tests passed.")

      allow(tool_executor).to receive(:execute).and_return(
        Rubino::Tools::Result.success(name: "test", call_id: "c1", output: "ok")
      )

      result = build_loop.run(messages: user_messages("run the tests"), tools: tools)

      injected = message_store.for_session(session[:id])
                              .select { |m| m.role == "user" }
                              .map(&:content)
      # First injection: the full named challenge.
      expect(injected.any? { |c| c.match?(/issued NO tool call/i) }).to be(true)
      # Second injection: the decayed, short atomic instruction (no heavy framing).
      expect(injected.any? { |c| c.match?(/Still no tool call/i) }).to be(true)
      expect(result).to eq("Tests passed.")
    end
  end

  describe "blocked/denied-but-claims is replaced with the honest message (F1/F2)" do
    # Drive a real noninteractive BLOCK: the model calls write, the executor
    # denies it as :noninteractive (headless fail-closed), and the model then
    # hands back a fabricated 'ready to git apply' diff for a file it never wrote.
    # The guard must REPLACE that with the honest "blocked, nothing applied, use
    # --yolo" message — the fabricated diff must NOT reach the user.
    let(:blocked_result) do
      Rubino::Tools::Result.denied(name: "write", call_id: "c1", reason: :noninteractive)
    end

    let(:fabricated_diff) do
      <<~TXT
        The rename is complete and ready to apply with `git apply`:

        --- a/shopkit/invoice.py
        +++ b/shopkit/invoice.py
        @@ -1,2 +1,2 @@
        -from shopkit.pricing import calc_total
        +from shopkit.pricing import compute_subtotal
      TXT
    end

    it "replaces a fabricated 'git apply' diff after a headless block with --yolo guidance" do
      fake_llm.enqueue_tool_call("write", { "path" => "/work/shopkit/invoice.py", "content" => "x" })
      fake_llm.enqueue_text(fabricated_diff)

      # Stub the executor to BLOCK the write headlessly, routing through the
      # loop's on_result sink exactly like production so @denied_count bumps and
      # the noninteractive reason is recorded.
      loop_obj = build_loop
      allow(tool_executor).to receive(:execute) do |name:, arguments:, call_id:|
        # Route through the loop's registered sink exactly like production so
        # @denied_count bumps and the noninteractive reason is recorded.
        loop_obj.send(:handle_tool_result, name: name, arguments: arguments,
                                           call_id: call_id, result: blocked_result)
        blocked_result
      end

      result = loop_obj.run(messages: user_messages("rename calc_total across the repo"),
                            tools: tools)

      # The fabricated diff hunks NEVER become the final answer (the honest
      # message itself mentions `git apply` only to say it is NOT applyable).
      expect(result).not_to include("@@")
      expect(result).not_to include("+++ b/")
      expect(result).not_to include("compute_subtotal")
      expect(result).not_to match(/ready to apply/i)
      # The honest blocked message is surfaced instead, naming --yolo (F2).
      expect(result).to match(/blocked/i)
      expect(result).to include("--yolo")
      expect(result).to match(/approvals\.mode: skip/i)
      stored = message_store.for_session(session[:id])
                            .select { |m| m.role == "assistant" }
                            .map(&:content)
      expect(stored.last).to match(/blocked/i)
    end
  end

  # #381 — PESSIMISTIC fabrication on the budget-exhausted summary path. The turn
  # actually ran tools (the loop forces a final summary once the iteration budget
  # is spent), but the model writes that summary claiming it did NOTHING. The
  # harness ledger is the authority on side-effects, so the loop reconciles the
  # false summary with a truthful note before it reaches/persists for the user.
  describe "budget-exhausted summary that pessimistically claims 'I did nothing' (#381)" do
    # Cap the budget at one tool iteration so iteration 2 fails can_continue? and
    # the loop takes summarize_on_budget_exhausted — the exact #381 trigger path.
    let(:config) { test_configuration("agent" => { "max_tool_iterations" => 1 }) }

    def write_result
      Rubino::Tools::Result.success(name: "write", call_id: "c1", output: "wrote 12 bytes")
    end

    # #418: the truthful harness note is a DIAGNOSTIC routed to STDERR (#warning)
    # + an event — NOT spliced into the returned text answer (which pollutes
    # `--output-format text` stdout, the clean-stdout contract). The pessimistic
    # claim itself still passes through cleanly as the answer; the note rides the
    # side channel.
    it "routes the harness note to stderr/event, NOT into the text answer (#381/#418)" do
      # Iteration 1: a REAL mutating tool call (counts as 1 tool, 1 edit).
      fake_llm.enqueue_tool_call("write", { "path" => "/work/a.rb", "content" => "x = 1" })
      # Budget now exhausted → the loop forces a summary. The model writes it
      # PESSIMISTICALLY, claiming nothing happened.
      fake_llm.enqueue_text("I have not read a single file, not run grep, not made any edits.")

      events = []
      event_bus.on(Rubino::Interaction::Events::HARNESS_NOTE) { |payload| events << payload }

      loop_obj = build_loop
      allow(tool_executor).to receive(:execute) do |name:, arguments:, call_id:|
        loop_obj.send(:handle_tool_result, name: name, arguments: arguments,
                                           call_id: call_id, result: write_result)
        write_result
      end

      result = loop_obj.run(messages: user_messages("refactor a.rb"), tools: tools)

      # The TEXT ANSWER (stdout) stays CLEAN — no harness note pollution.
      expect(result).not_to match(/harness note/i)
      expect(result).to eq("I have not read a single file, not run grep, not made any edits.")

      # The note went to the stderr-bound #warning channel + the event bus.
      warnings = null_ui.messages.select { |m| m[:level] == :warning }.map { |m| m[:message] }
      expect(warnings.join("\n")).to match(/harness note/i)
      expect(warnings.join("\n")).to match(/1 tool call actually ran/i)
      expect(warnings.join("\n")).to match(/1 edit\b/)
      expect(events.size).to eq(1)
      expect(events.first[:note]).to match(/uncommitted changes/i)

      # The clean answer (not the note) is what gets persisted as the assistant turn.
      stored = message_store.for_session(session[:id])
                            .select { |m| m.role == "assistant" }
                            .map(&:content)
      expect(stored.last).not_to match(/harness note/i)
    end

    it "leaves a TRUTHFUL budget-exhausted summary that names its tools untouched" do
      fake_llm.enqueue_tool_call("write", { "path" => "/work/a.rb", "content" => "x = 1" })
      fake_llm.enqueue_text("I edited a.rb and ran the suite — refactor is on disk, tests pass.")

      loop_obj = build_loop
      allow(tool_executor).to receive(:execute) do |name:, arguments:, call_id:|
        loop_obj.send(:handle_tool_result, name: name, arguments: arguments,
                                           call_id: call_id, result: write_result)
        write_result
      end

      result = loop_obj.run(messages: user_messages("refactor a.rb"), tools: tools)

      expect(result).to eq("I edited a.rb and ran the suite — refactor is on disk, tests pass.")
      expect(result).not_to match(/harness note/i)
    end
  end

  # #84 — the SAME pessimistic reconciliation, but on the NORMAL closing summary
  # (not the forced budget-exhausted one). After accepting "Continue (+N)" the
  # turn runs more tools/edits and then ends with an ORDINARY text answer; that
  # answer never passed through the ledger guard before (#evaluate bails the
  # moment tools ran). If the closing summary calls real, on-disk work "not
  # started / queued but unstarted", the loop now reconciles it via the same
  # harness note on the text_only? exit. Budget is NOT capped here, so the
  # summary is a genuine final answer — exactly the path #381 missed.
  describe "normal closing summary that claims a SPECIFIC item un-started (#84)" do
    def write_result
      Rubino::Tools::Result.success(name: "write", call_id: "c1", output: "wrote 12 bytes")
    end

    it "reconciles 'tags field not started / author queued but unstarted' against the ledger" do
      # Iteration 1: a REAL mutating tool call (the turn DID edit the files).
      fake_llm.enqueue_tool_call("write", { "path" => "/work/m.rb", "content" => "tags" })
      # Iteration 2: an ordinary closing summary — pessimistic about SPECIFIC items
      # that are actually on disk. Budget is NOT exhausted, so this is the normal
      # text_only? exit, not the forced-summary path.
      fake_llm.enqueue_text(
        "I added the validation logic. The tags field is not started, and the " \
        "accented lf author is queued but unstarted."
      )

      events = []
      event_bus.on(Rubino::Interaction::Events::HARNESS_NOTE) { |payload| events << payload }

      loop_obj = build_loop
      allow(tool_executor).to receive(:execute) do |name:, arguments:, call_id:|
        loop_obj.send(:handle_tool_result, name: name, arguments: arguments,
                                           call_id: call_id, result: write_result)
        write_result
      end

      result = loop_obj.run(messages: user_messages("add a tags field and an accented lf author"),
                            tools: tools)

      # The model's summary still reaches the user verbatim (clean stdout, #418) —
      # the truthful note rides the side channel, never spliced into the answer.
      expect(result).to match(/queued but unstarted/i)
      expect(result).not_to match(/harness note/i)

      warnings = null_ui.messages.select { |m| m[:level] == :warning }.map { |m| m[:message] }
      expect(warnings.join("\n")).to match(/1 tool call actually ran/i)
      expect(warnings.join("\n")).to match(/1 edit\b/)
      expect(events.size).to eq(1)
      expect(events.first[:note]).to match(/uncommitted changes/i)
    end

    it "leaves a truthful 'both items are on disk' closing summary untouched" do
      fake_llm.enqueue_tool_call("write", { "path" => "/work/m.rb", "content" => "tags" })
      fake_llm.enqueue_text("Added the tags field and renamed the author to lf — both on disk.")

      events = []
      event_bus.on(Rubino::Interaction::Events::HARNESS_NOTE) { |payload| events << payload }

      loop_obj = build_loop
      allow(tool_executor).to receive(:execute) do |name:, arguments:, call_id:|
        loop_obj.send(:handle_tool_result, name: name, arguments: arguments,
                                           call_id: call_id, result: write_result)
        write_result
      end

      result = loop_obj.run(messages: user_messages("add a tags field and an accented lf author"),
                            tools: tools)

      expect(result).to match(/both on disk/i)
      expect(events).to be_empty
      warnings = null_ui.messages.select { |m| m[:level] == :warning }.map { |m| m[:message] }
      expect(warnings.join("\n")).not_to match(/tool call actually ran/i)
    end
  end

  describe "cd claim is rewritten honestly (rubino has no cd tool)" do
    it "replaces 'Changed directory ...' with the honest no-cd answer" do
      fake_llm.enqueue_text("Changed the working directory to /tmp/elsewhere and confirmed.")

      result = build_loop.run(messages: user_messages("cd /tmp/elsewhere"), tools: tools)

      expect(result).to include("/add-dir")
      expect(result).to match(/can't change my working directory|no `cd` tool/)
      expect(result).not_to match(/Changed the working directory.*confirmed/)

      # The persisted assistant turn is the honest one, not the fabricated claim.
      stored = message_store.for_session(session[:id])
                            .select { |m| m.role == "assistant" }
                            .map(&:content)
      expect(stored.last).to include("/add-dir")
    end
  end
end
