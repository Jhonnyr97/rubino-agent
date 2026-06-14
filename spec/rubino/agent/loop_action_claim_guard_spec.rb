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

    it "stops HONESTLY after the reflection cap rather than fabricating forever" do
      # The model keeps narrating without ever calling a tool. The guard reflects
      # MAX_REFLECTIONS times, then surfaces the last text (still no fake success
      # silently accepted on the FIRST toolless turn).
      (Rubino::Agent::ActionClaimGuard::MAX_REFLECTIONS + 2).times do
        fake_llm.enqueue_text("Running the suite now.")
      end

      result = build_loop.run(messages: user_messages, tools: tools)

      # It still terminates (didn't loop forever) and the corrective prompt was
      # issued the capped number of times.
      reflections = message_store.for_session(session[:id])
                                 .map(&:content)
                                 .count { |c| c.to_s.match?(/issued NO tool call/i) }
      expect(reflections).to eq(Rubino::Agent::ActionClaimGuard::MAX_REFLECTIONS)
      expect(result).to be_a(String)
    end

    it "passes a genuine text answer straight through (no tool claim, no nag)" do
      fake_llm.enqueue_text("The mean of [1,2,3] is 2.")
      result = build_loop.run(messages: user_messages("what is the mean"), tools: tools)
      expect(result).to eq("The mean of [1,2,3] is 2.")
      contents = message_store.for_session(session[:id]).map(&:content)
      expect(contents.join("\n")).not_to match(/issued NO tool call/i)
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
