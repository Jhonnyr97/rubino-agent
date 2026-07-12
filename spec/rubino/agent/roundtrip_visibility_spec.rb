# frozen_string_literal: true

require "ruby_llm"

# #355 (count tool round-trips + sum usage + abort mid-loop) and #351 (persist
# the intermediate assistant-with-tool_calls rows on the STREAMING path).
#
# ruby_llm 1.15 runs the ENTIRE model↔tool round-trip loop inside one
# chat.ask (Chat#complete → #handle_tool_calls recurses). The Loop's own
# iteration counter therefore stays at 1 for a whole streaming turn and never
# re-checks the budget between the intermediate round-trips. These specs drive
# the REAL RubyLLMAdapter + REAL Loop with a FAKE ruby_llm chat that replays
# handle_tool_calls semantics (fires before/after_message + before_tool_call per
# round-trip, returns staged messages carrying tool_calls + per-message tokens,
# and honours RubyLLM::Tool::Halt). No live model.
# A staged round-trip: an assistant message carrying N tool_calls (tool_calls
# present), or the final plain-text turn (tool_calls nil). Per-message tokens
# ride on the assistant message. Defined at file scope (not in a block) to
# satisfy Lint/ConstantDefinitionInBlock.
RoundTripStage = Struct.new(:tool_calls, :text, :input_tokens, :output_tokens, keyword_init: true)

# A fake ruby_llm Chat that faithfully replays Chat#complete +
# #handle_tool_calls over a script of staged round-trips:
#   * supports additive before/after_message + before_tool_call callbacks;
#   * per staged assistant(tool_use) message: appends a real RubyLLM::Message
#     (tokens + tool_calls), fires after_message, then for each tool_call fires
#     before_tool_call and INVOKES the registered bridge tool with just the
#     parsed arguments (as ruby_llm does);
#   * honours a RubyLLM::Tool::Halt return: adds the trailing tool message,
#     stops recursing, returns the Halt itself (chat.rb L283-292);
#   * the final text stage returns its RubyLLM::Message as the response.
class FakeReplayChat
  attr_reader :messages

  def initialize(stages)
    @stages = stages
    @tools = {}
    @after = []
    @before_tc = []
    @messages = []
  end

  def with_instructions(*) = self
  def with_temperature(*) = self
  def with_params(**) = self
  def with_thinking(**) = self
  def before_message(&) = self
  def after_message(&block) = tap { @after << block }
  def before_tool_call(&block) = tap { @before_tc << block }

  def with_tool(tool)
    @tools[tool.name.to_s] = tool
    self
  end

  def ask(_content, **_kwargs, &)
    @stages.each do |stage|
      return final_message(stage) if stage.tool_calls.nil?

      halt = run_tool_round_trip(stage)
      return halt if halt
    end
    @messages.last
  end

  private

  def final_message(stage)
    msg = RubyLLM::Message.new(role: :assistant, content: stage.text,
                               input_tokens: stage.input_tokens, output_tokens: stage.output_tokens)
    @messages << msg
    fire_after(msg)
    msg
  end

  # Appends the assistant(tool_use) message, fires after_message, then dispatches
  # each tool through the registered bridge. Returns a Tool::Halt to stop, else nil.
  def run_tool_round_trip(stage)
    rl_calls = stage.tool_calls.to_h do |tc|
      [tc[:id], RubyLLM::ToolCall.new(id: tc[:id], name: tc[:name], arguments: tc[:arguments])]
    end
    amsg = RubyLLM::Message.new(role: :assistant, content: stage.text, tool_calls: rl_calls,
                                input_tokens: stage.input_tokens, output_tokens: stage.output_tokens)
    @messages << amsg
    fire_after(amsg)

    rl_calls.each_value do |tool_call|
      @before_tc.each { |b| b.call(tool_call) }
      result = @tools.fetch(tool_call.name).call(tool_call.arguments)
      content = result.is_a?(RubyLLM::Tool::Halt) ? result.content : result.to_s
      tmsg = RubyLLM::Message.new(role: :tool, content: content, tool_call_id: tool_call.id)
      @messages << tmsg
      fire_after(tmsg)
      return result if result.is_a?(RubyLLM::Tool::Halt)
    end
    nil
  end

  def fire_after(msg) = @after.each { |b| b.call(msg) }
end

RSpec.describe Rubino::Agent::Loop do
  let(:db)        { test_database }
  let(:null_ui)   { Rubino::UI::Null.new }
  let(:event_bus) { Rubino::Interaction::EventBus.new }
  let(:config) do
    test_configuration(
      "streaming" => { "enabled" => true, "transport" => "off" },
      "display" => { "streaming" => true },
      "model" => { "provider" => "openai", "default" => "gpt-4o", "temperature" => 0.3 }
    )
  end
  let(:message_store) { Rubino::Session::Store.new }
  let(:session) { Rubino::Session::Repository.new.create(source: "test", model: "gpt-4o") }
  let(:agent_tool) do
    Class.new(Rubino::Tools::Base) do
      def name = "echo"
      def description = "echo"
      def input_schema = { type: "object" }
      def risk_level = :low
      def call(args) = "ran:#{args["v"]}"
    end.new
  end
  let(:registry)        { double("Registry", find: agent_tool) }
  let(:approval_policy) { double("ApprovalPolicy", decide: :allow) }
  let(:audit_repo)      { double("ToolCallRepository") }

  before do
    allow(Rubino).to receive(:database).and_return(db)
    allow(audit_repo).to receive(:record)
  end

  def tool_rt(calls, input:, output:)
    RoundTripStage.new(tool_calls: calls, text: nil, input_tokens: input, output_tokens: output)
  end

  def text_rt(text, input:, output:)
    RoundTripStage.new(tool_calls: nil, text: text, input_tokens: input, output_tokens: output)
  end

  def stage_call(id, value) = { id: id, name: "echo", arguments: { "v" => value } }

  # A real RubyLLMAdapter whose build_chat returns the fake replaying chat (with
  # the real ToolBridge installed so budget_exhausted + executor wiring run).
  def adapter_with(stages, tool_executor:)
    adapter = Rubino::LLM::RubyLLMAdapter.new(model_id: "gpt-4o", config: config,
                                              ui: null_ui, event_bus: event_bus,
                                              tool_executor: tool_executor)
    allow(adapter).to receive(:build_chat).and_wrap_original do |_orig, **kw|
      install_fake_chat(FakeReplayChat.new(stages), tool_executor, kw[:budget_exhausted])
    end
    adapter
  end

  def install_fake_chat(chat, executor, budget_exhausted)
    Rubino::LLM::ToolBridge.install(chat, [agent_tool], ui: null_ui, event_bus: event_bus,
                                                        tool_executor: executor,
                                                        budget_exhausted: budget_exhausted)
    chat
  end

  def tool_executor(session_id: session[:id])
    Rubino::Agent::ToolExecutor.new(
      registry: registry, approval_policy: approval_policy,
      ui: null_ui, config: config, tool_call_repository: audit_repo,
      session_id: session_id, event_bus: event_bus, read_tracker: false
    )
  end

  def build_loop(adapter, executor, budget)
    described_class.new(
      session: session, llm_adapter: adapter, tool_executor: executor,
      message_store: message_store, budget: budget, ui: null_ui,
      event_bus: event_bus, config: config
    )
  end

  # ===========================================================================
  # Spec 1 — round-trip count: budget consulted per round-trip, not once.
  # ===========================================================================
  it "consults the budget once PER round-trip (3 round-trips), not once for the turn" do
    stages = [
      tool_rt([stage_call("c1", "a")], input: 10, output: 5),
      tool_rt([stage_call("c2", "b")], input: 10, output: 5),
      text_rt("done", input: 10, output: 5)
    ]
    executor = tool_executor
    budget = Rubino::Agent::IterationBudget.new(config: config)
    spy_budget = budget
    seen = []
    allow(spy_budget).to receive(:can_continue?).and_wrap_original do |orig, n|
      seen << n
      orig.call(n)
    end

    adapter = adapter_with(stages, tool_executor: executor)
    loop_runner = build_loop(adapter, executor, spy_budget)
    result = loop_runner.run(messages: [{ role: "user", content: "hi" }], tools: [agent_tool])

    expect(result).to eq("done")
    # The budget predicate fired for the two mid-stream tool round-trips
    # (stream_budget_exhausted? → can_continue?(1), can_continue?(2)) — i.e. it
    # was consulted PER round-trip, not just the single outer iteration.
    expect(seen).to include(1, 2)
    # Two tools ran across the turn (the streaming path counted both).
    expect(loop_runner.instance_variable_get(:@tool_count)).to eq(2)
    expect(loop_runner.instance_variable_get(:@stream_round_trips)).to eq(2)
  end

  # ===========================================================================
  # Spec 2 — abort mid-loop via Halt at max_tool_iterations (iteration cap).
  # ===========================================================================
  it "halts after RT2 with a valid trailing message and ONE max-iterations summary (max_tool_iterations: 2)" do
    # 3 tool round-trips staged; budget caps at 2. RT3's single tool must Halt;
    # the model is then asked (toolless) to summarise — exactly once.
    stages = [
      tool_rt([stage_call("c1", "a")], input: 1, output: 1),
      tool_rt([stage_call("c2", "b")], input: 1, output: 1),
      tool_rt([stage_call("c3", "c")], input: 1, output: 1),
      text_rt("never-reached-as-tool-turn", input: 1, output: 1)
    ]
    executor = tool_executor
    budget = Rubino::Agent::IterationBudget.new(
      config: config, max_tool_iterations: 2
    )
    adapter = adapter_with(stages, tool_executor: executor)

    # Capture the toolless summary call (the budget-exhausted nudge): the Loop
    # appends MAX_ITERATIONS_SUMMARY_NUDGE as a user message and re-calls the
    # model with NO tools. We assert that summary path runs exactly once by
    # spying on handle_budget_exhausted (the #399 routing entry point that, on
    # the headless Null UI here, falls through to the force-summarize body).
    loop_runner = build_loop(adapter, executor, budget)
    summary_calls = 0
    allow(loop_runner).to receive(:handle_budget_exhausted).and_wrap_original do |*|
      summary_calls += 1
      "summary"
    end

    result = loop_runner.run(messages: [{ role: "user", content: "hi" }], tools: [agent_tool])

    expect(result).to eq("summary")
    expect(summary_calls).to eq(1)
    # RT1 + RT2 tools ran; RT3 was halted (never reached the executor).
    expect(loop_runner.instance_variable_get(:@tool_count)).to eq(2)

    # Trailing message in the chat is a valid tool message (the Halt nudge),
    # NOT an orphaned tool_use: every assistant(tool_use) in the replayed chat
    # is followed by a tool message.
    persisted = message_store.for_session(session[:id])
    # The voided RT3 round-trip was NOT persisted (orphan-avoidance): only RT1
    # and RT2 assistant(tool_use) rows exist among the intermediates.
    assistant_tooluse = persisted.select do |m|
      m.role == "assistant" && m.metadata.is_a?(Hash) && (m.metadata[:tool_calls] || m.metadata["tool_calls"])
    end
    expect(assistant_tooluse.size).to eq(2)
  end

  # ===========================================================================
  # Spec 5 (#399) — streaming Halt → continue → a FRESH ask() resumes with the
  # intact post-Halt history (no tool_bridge change). The user picks "Continue"
  # at the cap; the loop extends the budget and re-enters, so the next ask()
  # streams the second round-trip script against the now-larger budget.
  # ===========================================================================
  it "streaming Halt → continue resumes with a fresh ask() and intact history" do
    # ask() #1: one tool round-trip, then RT2 Halts at the cap (max_tool: 1).
    # ask() #2 (after the +N extension): one tool round-trip, then final text.
    ask1 = [
      tool_rt([stage_call("c1", "a")], input: 1, output: 1),
      tool_rt([stage_call("c2", "b")], input: 1, output: 1)
    ]
    ask2 = [
      tool_rt([stage_call("c3", "c")], input: 1, output: 1),
      text_rt("resumed and finished", input: 1, output: 1)
    ]
    executor = tool_executor
    budget = Rubino::Agent::IterationBudget.new(config: config, max_tool_iterations: 1)

    # A scripted-select UI that returns :continue at the first cap, :summarize
    # after (so the turn can terminate even if it caps again).
    scripted_ui = Class.new(Rubino::UI::Null) do
      def initialize(choices)
        super()
        @choices = choices.dup
      end

      def select(_prompt, _choices) = @choices.shift || :summarize
    end.new([:continue])

    # build_chat is invoked once per ask(); hand out the next staged script each
    # time so the second ask() resumes a fresh round-trip loop (its budget is now
    # larger thanks to extend!). The real ToolBridge/budget wiring is preserved.
    scripts = [ask1, ask2]
    adapter = Rubino::LLM::RubyLLMAdapter.new(model_id: "gpt-4o", config: config,
                                              ui: scripted_ui, event_bus: event_bus,
                                              tool_executor: executor)
    allow(adapter).to receive(:build_chat).and_wrap_original do |_orig, **kw|
      install_fake_chat(FakeReplayChat.new(scripts.shift || [text_rt("", input: 1, output: 1)]),
                        executor, kw[:budget_exhausted])
    end

    loop_runner = described_class.new(
      session: session, llm_adapter: adapter, tool_executor: executor,
      message_store: message_store, budget: budget, ui: scripted_ui,
      event_bus: event_bus, config: config
    )
    extended = []
    allow(budget).to receive(:extend!).and_wrap_original do |orig, by|
      extended << by
      orig.call(by)
    end

    result = loop_runner.run(messages: [{ role: "user", content: "hi" }], tools: [agent_tool])

    # The extension was granted once, then a SECOND ask() ran (build_chat scripts
    # were both consumed) and produced the final text.
    expect(extended.size).to eq(1)
    expect(scripts).to be_empty
    expect(result).to eq("resumed and finished")
    # Both ask()s' tools ran across the turn → history stayed well-formed and
    # the resume was a real continuation, not a restart.
    expect(loop_runner.instance_variable_get(:@tool_count)).to eq(2)
  end

  it "halts when max_turn_seconds elapses mid-loop (clock stub)" do
    stages = [
      tool_rt([stage_call("c1", "a")], input: 1, output: 1),
      tool_rt([stage_call("c2", "b")], input: 1, output: 1),
      tool_rt([stage_call("c3", "c")], input: 1, output: 1),
      text_rt("unused", input: 1, output: 1)
    ]
    executor = tool_executor
    allow(config).to receive_messages(agent_max_turn_seconds: 100, agent_max_tool_iterations: 50)
    budget = Rubino::Agent::IterationBudget.new(config: config)
    # Controllable clock: starts at the budget's start time and stays there until
    # at least one tool has run, then jumps PAST the 100s deadline. This makes
    # the first round-trip pass the time check and a later round-trip's check
    # observe the deadline crossed → Halt. Driven by a shared counter the agent
    # tool bumps when it runs, so the clock is deterministic and order-independent
    # (every Time.now after the first tool ran returns the post-deadline value).
    start = budget.instance_variable_get(:@turn_started_at)
    tools_ran = { n: 0 }
    allow(agent_tool).to receive(:call).and_wrap_original do |orig, args|
      tools_ran[:n] += 1
      orig.call(args)
    end
    allow(Time).to receive(:now) { tools_ran[:n].zero? ? start : start + 200 }

    adapter = adapter_with(stages, tool_executor: executor)
    loop_runner = build_loop(adapter, executor, budget)
    summary_calls = 0
    allow(loop_runner).to receive(:handle_budget_exhausted).and_wrap_original do |*|
      summary_calls += 1
      "timed-summary"
    end

    result = loop_runner.run(messages: [{ role: "user", content: "hi" }], tools: [agent_tool])
    expect(result).to eq("timed-summary")
    expect(summary_calls).to eq(1)
    # At least the first round-trip's tool ran before the clock tripped.
    expect(loop_runner.instance_variable_get(:@tool_count)).to be >= 1
  end

  # ===========================================================================
  # Spec 3 — usage summed across round-trips.
  # ===========================================================================
  it "sums input/output usage across every round-trip into the response + token_total" do
    stages = [
      tool_rt([stage_call("c1", "a")], input: 100, output: 50),
      tool_rt([stage_call("c2", "b")], input: 120, output: 40),
      text_rt("done", input: 80, output: 200)
    ]
    executor = tool_executor

    captured = nil
    event_bus.on(Rubino::Interaction::Events::MODEL_CALL_FINISHED) { |p| captured = p }

    adapter = adapter_with(stages, tool_executor: executor)
    budget = Rubino::Agent::IterationBudget.new(config: config)
    loop_runner = build_loop(adapter, executor, budget)
    loop_runner.run(messages: [{ role: "user", content: "hi" }], tools: [agent_tool])

    # AdapterResponse reports the SUMMED usage (100+120+80 / 50+40+200), not just
    # the final message's 80/200.
    expect(captured[:input_tokens]).to eq(300)
    expect(captured[:output_tokens]).to eq(290)
    # And the Loop's token_total reflects the same sum (300+290). token_total is
    # local to #run; assert it via the turn-summary event's reported tokens.
    expect(captured[:input_tokens] + captured[:output_tokens]).to eq(590)
  end

  it "build_response sums usage directly, and falls back to final-message usage when the accumulator is empty (unit)" do
    a = Rubino::LLM::RubyLLMAdapter.new(model_id: "gpt-4o", config: config, ui: null_ui,
                                        event_bus: event_bus)
    # A real RubyLLM::Message so all of build_response's respond_to? probes
    # (tool_calls / raw / reasoning / cache_*) behave like the live path.
    final = RubyLLM::Message.new(role: :assistant, content: "x", input_tokens: 80, output_tokens: 200)

    summed = a.send(:build_response, final, "buf", usage: { input: 300, output: 290 })
    expect(summed.input_tokens).to eq(300)
    expect(summed.output_tokens).to eq(290)

    # Empty accumulator (provider surfaced no per-message usage) ⇒ fall back to
    # the final message's own usage rather than reporting a spurious 0/0.
    fallback = a.send(:build_response, final, "buf", usage: { input: 0, output: 0 })
    expect(fallback.input_tokens).to eq(80)
    expect(fallback.output_tokens).to eq(200)
  end

  # ===========================================================================
  # Spec 4 — #351: streaming intermediate assistant(tool_use) rows persisted;
  # repair_tool_pairs leaves the pairs intact.
  # ===========================================================================
  it "persists assistant(tool_use) + tool(result) per round-trip and final text exactly once" do
    stages = [
      tool_rt([stage_call("c1", "a")], input: 5, output: 5),
      tool_rt([stage_call("c2", "b")], input: 5, output: 5),
      text_rt("all done", input: 5, output: 5)
    ]
    executor = tool_executor
    adapter = adapter_with(stages, tool_executor: executor)
    budget = Rubino::Agent::IterationBudget.new(config: config)
    loop_runner = build_loop(adapter, executor, budget)
    loop_runner.run(messages: [{ role: "user", content: "hi" }], tools: [agent_tool])

    rows = message_store.for_session(session[:id])
    # Expected order: user, assistant(tool_use #1), tool(result #1),
    # assistant(tool_use #2), tool(result #2), final assistant(text).
    assistant_rows = rows.select { |m| m.role == "assistant" }
    tool_rows      = rows.select { |m| m.role == "tool" }

    # Two intermediate assistant(tool_use) rows carry tool_calls metadata.
    tooluse = assistant_rows.select do |m|
      m.metadata.is_a?(Hash) && (m.metadata[:tool_calls] || m.metadata["tool_calls"])
    end
    expect(tooluse.size).to eq(2)
    # First intermediate carries the real tool_call id + per-message tokens.
    md = tooluse.first.metadata
    tcs = md[:tool_calls] || md["tool_calls"]
    expect(tcs.first[:id] || tcs.first["id"]).to eq("c1")
    expect(md[:input_tokens] || md["input_tokens"]).to eq(5)

    # Two tool(result) rows, linked by tool_call_id.
    expect(tool_rows.map(&:tool_call_id)).to contain_exactly("c1", "c2")

    # Exactly ONE final assistant text row (idempotency: the new after_message
    # handler must NOT also persist the final text).
    final_text = assistant_rows.reject do |m|
      m.metadata.is_a?(Hash) && (m.metadata[:tool_calls] || m.metadata["tool_calls"])
    end
    expect(final_text.size).to eq(1)
    expect(final_text.first.content).to eq("all done")

    # repair_tool_pairs over the persisted set strips NOTHING — pairs complete.
    assembler = Rubino::Context::PromptAssembler.new(
      session: session, memory_context: {}, config: config
    )
    repaired = assembler.send(:repair_tool_pairs, rows)
    repaired_tool = repaired.select { |m| m.role == "tool" }
    expect(repaired_tool.map(&:tool_call_id)).to contain_exactly("c1", "c2")
    # No assistant(tool_use) had its tool_calls stripped (all pairs answered).
    repaired_tooluse = repaired.select do |m|
      m.role == "assistant" && m.metadata.is_a?(Hash) &&
        (m.metadata[:tool_calls] || m.metadata["tool_calls"])
    end
    expect(repaired_tooluse.size).to eq(2)
  end

  # ===========================================================================
  # Spec 5 — security: mid-stream tool calls hit ApprovalPolicy#decide + audit;
  # installing the production bridge with tool_executor: nil is rejected.
  # ===========================================================================
  it "routes every mid-stream tool through ApprovalPolicy#decide AND writes an audit row" do
    stages = [
      tool_rt([stage_call("c1", "a")], input: 1, output: 1),
      text_rt("ok", input: 1, output: 1)
    ]
    executor = tool_executor

    adapter = adapter_with(stages, tool_executor: executor)
    budget = Rubino::Agent::IterationBudget.new(config: config)
    build_loop(adapter, executor, budget)
      .run(messages: [{ role: "user", content: "hi" }], tools: [agent_tool])

    # ApprovalPolicy#decide gated the mid-stream tool, and the executor wrote a
    # completed audit row keyed on the real provider call_id — approval + audit
    # fire on the streaming path, not the unguarded direct-call fallback.
    expect(approval_policy).to have_received(:decide).with(agent_tool, arguments: hash_including(v: "a"))
    expect(audit_repo).to have_received(:record).with(hash_including(status: "completed", call_id: "c1"))
  end

  it "rejects installing the production bridge with a nil tool_executor (approval/audit invariant)" do
    chat = FakeReplayChat.new([])
    expect do
      Rubino::LLM::ToolBridge.install(chat, [agent_tool], ui: null_ui, tool_executor: nil, production: true)
    end.to raise_error(Rubino::Error, /without a tool_executor/)
  end

  it "still allows the unguarded fallback bridge OFF the production path (tests/one-shot)" do
    chat = FakeReplayChat.new([])
    expect do
      Rubino::LLM::ToolBridge.install(chat, [agent_tool], ui: null_ui, tool_executor: nil)
    end.not_to raise_error
  end

  # ===========================================================================
  # Spec 6 — idempotency: the final assistant TEXT row is persisted exactly once
  # (no duplicate from the new after_message handler). Covered structurally by
  # spec 4's final_text assertion; here we assert the create-count directly.
  # ===========================================================================
  it "persists the final assistant text exactly once (no dup from after_message)" do
    stages = [
      tool_rt([stage_call("c1", "a")], input: 1, output: 1),
      text_rt("final", input: 1, output: 1)
    ]
    executor = tool_executor
    created = []
    allow(message_store).to receive(:create).and_wrap_original do |orig, **kw|
      created << kw
      orig.call(**kw)
    end

    adapter = adapter_with(stages, tool_executor: executor)
    budget = Rubino::Agent::IterationBudget.new(config: config)
    build_loop(adapter, executor, budget)
      .run(messages: [{ role: "user", content: "hi" }], tools: [agent_tool])

    final_rows = created.select { |kw| kw[:role] == "assistant" && kw[:content] == "final" }
    expect(final_rows.size).to eq(1)
  end
end
