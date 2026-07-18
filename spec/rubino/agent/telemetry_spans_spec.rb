# frozen_string_literal: true

require "opentelemetry/sdk"

# End-to-end contract of the three instrumentation hooks (Rubino::Telemetry):
# the `chat` span around ModelCallRunner#call!, the `execute_tool` span around
# ToolExecutor#execute and the `invoke_agent` span around Lifecycle#execute —
# names, GenAI-semconv attributes, and the capture_content privacy gate.
RSpec.describe "Telemetry spans" do # rubocop:disable RSpec/DescribeClass
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }

  before do
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    Rubino::Telemetry.instance_variable_set(:@enabled, true)
    Rubino::Telemetry.instance_variable_set(:@tracer, provider.tracer("test"))
  end

  after { Rubino::Telemetry.reset! }

  def finished_span
    expect(exporter.finished_spans.size).to eq(1)
    exporter.finished_spans.first
  end

  describe "ModelCallRunner → chat span" do
    # Minimal boundary: returns the scripted response, exposes model/provider
    # identity like RubyLLMAdapter's attr_readers.
    let(:boundary) do
      response = Rubino::LLM::AdapterResponse.new(
        content: "the answer", tool_calls: [], input_tokens: 11, output_tokens: 5,
        model_id: "test-model-v2", stop_reason: :end_turn
      )
      double("Boundary", call: response, model_id: "test-model", provider: "anthropic")
    end

    let(:runner) do
      Rubino::Agent::ModelCallRunner.new(
        llm: boundary, config: test_configuration, ui: Rubino::UI::Null.new,
        event_bus: Rubino::Interaction::EventBus.new
      )
    end

    let(:request) { Rubino::LLM::Request.new(messages: [{ role: "user", content: "hi" }]) }

    it "wraps the call in a client-kind `chat <model>` span with usage attributes" do
      runner.call!(request, iteration: 3)
      span = finished_span
      expect(span.name).to eq("chat test-model")
      expect(span.kind).to eq(:client)
      expect(span.attributes).to include(
        "gen_ai.operation.name" => "chat",
        "gen_ai.provider.name" => "anthropic",
        "gen_ai.request.model" => "test-model",
        "gen_ai.response.model" => "test-model-v2",
        "gen_ai.response.finish_reasons" => ["end_turn"],
        "gen_ai.usage.input_tokens" => 11,
        "gen_ai.usage.output_tokens" => 5,
        "rubino.iteration" => 3
      )
    end

    it "exports no message text unless capture_content opts in" do
      runner.call!(request)
      expect(finished_span.attributes.keys).not_to include("gen_ai.input.messages", "gen_ai.output.messages")
    end

    it "exports redacted message text under the capture_content opt-in" do
      allow(Rubino::Telemetry).to receive(:capture_content?).and_return(true)
      runner.call!(request)
      span = finished_span
      expect(span.attributes["gen_ai.input.messages"]).to include('"content":"hi"')
      expect(span.attributes["gen_ai.output.messages"]).to include("the answer")
    end
  end

  describe "ToolExecutor → execute_tool span" do
    let(:tool) do
      Class.new(Rubino::Tools::Base) do
        def name = "fake_tool"
        def description = "fake"
        def input_schema = { type: "object" }
        def call(_args) = "tool output"
      end.new
    end

    let(:executor) do
      Rubino::Agent::ToolExecutor.new(
        registry: double("Registry", find: tool), approval_policy: policy,
        ui: double("UI", confirm: true, interactive?: true), config: test_configuration
      )
    end

    let(:policy) { double("ApprovalPolicy", decide: :allow, workspace_widen_dirs: []) }

    it "wraps the run in an `execute_tool <name>` span with success status" do
      executor.execute(name: "fake_tool", arguments: { "x" => 1 }, call_id: "call_9")
      span = finished_span
      expect(span.name).to eq("execute_tool fake_tool")
      expect(span.attributes).to include(
        "gen_ai.operation.name" => "execute_tool",
        "gen_ai.tool.name" => "fake_tool",
        "gen_ai.tool.call.id" => "call_9",
        "rubino.tool.status" => "success"
      )
      expect(span.attributes.keys).not_to include("gen_ai.tool.call.arguments", "gen_ai.tool.call.result")
    end

    it "marks a policy-denied call denied — the span still exists" do
      allow(policy).to receive_messages(decide: :deny, last_deny_reason: nil)
      executor.execute(name: "fake_tool", arguments: {}, call_id: "call_9")
      expect(finished_span.attributes["rubino.tool.status"]).to eq("denied")
    end

    it "exports arguments/output only under the capture_content opt-in" do
      allow(Rubino::Telemetry).to receive(:capture_content?).and_return(true)
      executor.execute(name: "fake_tool", arguments: { "x" => 1 }, call_id: "call_9")
      span = finished_span
      expect(span.attributes["gen_ai.tool.call.arguments"]).to include('"x":1')
      expect(span.attributes["gen_ai.tool.call.result"]).to include("tool output")
    end
  end

  describe "AuxiliaryClient → aux chat span" do
    let(:config) do
      test_configuration("auxiliary" => { "summarize" => { "provider" => "fake", "model" => "fake/happy-path" } })
    end

    it "wraps the aux call in a task-tagged `chat` span with usage attributes" do
      response = Rubino::LLM::AdapterResponse.new(
        content: "a summary", tool_calls: [], input_tokens: 9, output_tokens: 3, model_id: "aux-model"
      )
      adapter = double("Adapter", model_id: "aux-model", provider: "fake", chat: response)
      allow(Rubino::LLM::AdapterFactory).to receive(:build).and_return(adapter)

      Rubino::LLM::AuxiliaryClient.new(config: config).call(task: :summarize,
                                                            messages: [{
                                                              role: "user", content: "x"
                                                            }])

      span = finished_span
      expect(span.name).to eq("chat aux-model")
      expect(span.attributes).to include(
        "gen_ai.operation.name" => "chat",
        "rubino.aux.task" => "summarize",
        "gen_ai.request.model" => "aux-model",
        "gen_ai.usage.input_tokens" => 9,
        "gen_ai.usage.output_tokens" => 3
      )
      expect(span.attributes.keys).not_to include("gen_ai.input.messages")
    end
  end

  describe "Lifecycle → search_memory span" do
    it "records the recall with a relevant-memories count and no query text by default" do
      config = test_configuration("memory" => { "enabled" => true })
      backend = double("MemoryBackend", user_profile: nil, project_context: nil,
                                        retrieve: [{ text: "fact one" }, { text: "fact two" }])
      allow(Rubino::Memory::Backends).to receive(:build).and_return(backend)
      lifecycle = Rubino::Interaction::Lifecycle.new(
        session: { id: "sess-3" }, event_bus: Rubino::Interaction::EventBus.new,
        ui: Rubino::UI::Null.new, config: config
      )

      context = lifecycle.send(:load_memory, "what did we decide?")

      expect(context[:relevant_memories].size).to eq(2)
      span = finished_span
      expect(span.name).to eq("search_memory")
      expect(span.attributes).to include(
        "gen_ai.operation.name" => "search_memory",
        "rubino.memory.relevant_count" => 2
      )
      expect(span.attributes.keys).not_to include("gen_ai.memory.query.text")
    end
  end

  describe "Lifecycle → invoke_agent span" do
    let(:lifecycle) do
      Rubino::Interaction::Lifecycle.new(
        session: { id: "sess-1" }, event_bus: Rubino::Interaction::EventBus.new,
        ui: Rubino::UI::Null.new, config: test_configuration
      )
    end

    it "wraps the turn in an `invoke_agent` span carrying the conversation id and stop reason" do
      allow(lifecycle).to receive(:run_interaction) do
        lifecycle.instance_variable_set(:@last_stop_reason, :completed)
        "final answer"
      end
      expect(lifecycle.execute("hi")).to eq("final answer")
      span = finished_span
      expect(span.name).to eq("invoke_agent rubino")
      expect(span.attributes).to include(
        "gen_ai.operation.name" => "invoke_agent",
        "gen_ai.agent.name" => "rubino",
        "gen_ai.conversation.id" => "sess-1",
        "rubino.turn.stop_reason" => "completed"
      )
    end

    it "names the span after the subagent definition when delegated" do
      definition = double("Definition", name: "researcher")
      delegated = Rubino::Interaction::Lifecycle.new(
        session: { id: "sess-2" }, event_bus: Rubino::Interaction::EventBus.new,
        ui: Rubino::UI::Null.new, config: test_configuration, agent_definition: definition
      )
      allow(delegated).to receive(:run_interaction).and_return("done")
      delegated.execute("hi")
      expect(finished_span.name).to eq("invoke_agent researcher")
    end
  end
end
