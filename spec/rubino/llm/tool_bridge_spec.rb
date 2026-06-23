# frozen_string_literal: true

require "tmpdir"

# STRM-2: on the STREAMING path ruby_llm dispatches a tool via the bridge and
# only hands it the parsed ARGUMENTS — not the tool_call object. ToolBridge must
# capture the real tool_call id (via the before_tool_call callback ruby_llm
# fires immediately before each sequential dispatch) and thread it through to
# ToolExecutor#execute as call_id. Without that:
#   * spill_full_output early-returns (id empty) → the "full output saved to
#     <path>" recovery file is never written, even though the model is told it
#     was elided;
#   * the tool_calls audit row is keyed on a random uuid, not the provider id,
#     and messages.tool_call_id can never be linked back.
RSpec.describe Rubino::LLM::ToolBridge do
  # Minimal stand-in for a ruby_llm Chat: records the before_tool_call callback
  # and the registered bridge, then replays ruby_llm's sequential dispatch —
  # fire before_tool_call(tool_call), then invoke the tool with just the parsed
  # arguments (ruby_llm never hands the bridge the tool_call object).
  let(:fake_chat_class) do
    Class.new do
      attr_reader :tools

      def initialize
        @tools = []
        @before_tool_call = nil
      end

      def before_tool_call(&block)
        @before_tool_call = block
      end

      def with_tool(tool)
        @tools << tool
        self
      end

      def dispatch(tool_call)
        @before_tool_call&.call(tool_call)
        @tools.find { |t| t.name == tool_call.name }.call(tool_call.arguments)
      end
    end
  end

  let(:tool_call_class) { Struct.new(:id, :name, :arguments) }
  let(:chat) { fake_chat_class.new }

  let(:agent_tool) do
    Class.new(Rubino::Tools::Base) do
      def name = "fake_tool"
      def description = "fake"
      def input_schema = { type: "object" }
      def risk_level = :low
      attr_writer :output

      def call(_args)
        @output
      end
    end.new
  end

  let(:registry) { double("Registry", find: agent_tool) }
  let(:policy)   { double("ApprovalPolicy", decide: :allow) }
  let(:ui)       { double("UI", confirm: true, interactive?: true) }
  let(:repo)     { double("Repo") }
  let(:config)   { Rubino.configuration }
  let(:spill_home) { Dir.mktmpdir("strm2_home") }

  let(:executor) do
    Rubino::Agent::ToolExecutor.new(registry: registry, approval_policy: policy,
                                    ui: ui, config: config,
                                    tool_call_repository: repo, session_id: "sess-1")
  end

  after { FileUtils.rm_rf(spill_home) }
  before { allow(Rubino).to receive(:home_path).and_return(spill_home) }

  def tool_call(id, name, arguments)
    tool_call_class.new(id, name, arguments)
  end

  it "threads the real tool_call id into ToolExecutor#execute (not nil)" do
    seen = nil
    allow(executor).to receive(:execute).and_wrap_original do |orig, **kw|
      seen = kw[:call_id]
      orig.call(**kw)
    end
    allow(repo).to receive(:record)
    agent_tool.output = "ok"

    described_class.install(chat, [agent_tool], ui: ui, event_bus: nil, tool_executor: executor)
    chat.dispatch(tool_call("call_abc123", "fake_tool", { "x" => 1 }))

    expect(seen).to eq("call_abc123")
  end

  it "writes the spill recovery file and records the real call_id on overflow" do
    recorded = nil
    allow(repo).to receive(:record) { |**kw| recorded = kw }
    # Output over the 50_000-byte model-facing cap so truncate spills.
    agent_tool.output = "Z" * 120_000

    described_class.install(chat, [agent_tool], ui: ui, event_bus: nil, tool_executor: executor)
    model_facing = chat.dispatch(tool_call("call_spill_1", "fake_tool", {}))

    spill_path = File.join(spill_home, "tool-results", "call_spill_1.txt")
    expect(File).to exist(spill_path)
    expect(File.read(spill_path).bytesize).to eq(120_000)
    expect(model_facing).to include("full output saved to #{spill_path}")
    expect(recorded[:call_id]).to eq("call_spill_1")
  end

  it "still falls back to nil id when no executor (test/one-shot bridge)" do
    allow(ui).to receive(:tool_started)
    allow(ui).to receive(:tool_finished)
    agent_tool.output = "ok"

    described_class.install(chat, [agent_tool], ui: ui, event_bus: nil, tool_executor: nil)
    expect(chat.dispatch(tool_call("call_x", "fake_tool", {}))).to eq("ok")
  end

  # FINDING #48 / #52: the tool-dispatch BOUNDARY. ruby_llm runs the whole
  # model↔tool loop inside one ask(); the only in-loop cancel poll is the
  # per-chunk streaming callback. A user interrupt that lands BETWEEN a tool
  # returning and ruby_llm issuing the next round-trip request used to go
  # unnoticed: ruby_llm sent a malformed continuation the provider rejected
  # ("invalid params", #48) and the unwind lagged until the post-cancel stream
  # settled (16–21s, #52). The bridge now checks the turn's CancelToken at the
  # boundary — before AND after each mid-stream dispatch — so the interrupt
  # surfaces PROMPTLY as a clean Rubino::Interrupted and no doomed request is
  # ever issued.
  describe "cancel-token boundary check (#48/#52)" do
    let(:token) { Rubino::Interaction::CancelToken.new }

    it "raises Interrupted at the post-return boundary when the user cancelled DURING the tool" do
      allow(repo).to receive(:record)
      # Mimics a long shell command SIGTERM-settled by Esc: the cancel flips
      # while the tool runs, and the tool RETURNS NORMALLY (cancelled output) —
      # it does not raise. Without the boundary check, control would flow back
      # to ruby_llm and a continuation request would go out before the interrupt
      # is noticed.
      flip = token
      agent_tool.define_singleton_method(:call) do |_args|
        flip.cancel!
        "[Command cancelled by user — SIGTERM sent]"
      end

      described_class.install(chat, [agent_tool], ui: ui, event_bus: nil,
                                                  tool_executor: executor, cancel_token: token)

      expect { chat.dispatch(tool_call("call_late", "fake_tool", {})) }
        .to raise_error(Rubino::Interrupted)
    end

    it "raises Interrupted BEFORE running the tool when the token is already cancelled" do
      token.cancel!
      ran = false
      agent_tool.define_singleton_method(:call) do |_args|
        ran = true
        "should not run"
      end

      described_class.install(chat, [agent_tool], ui: ui, event_bus: nil,
                                                  tool_executor: executor, cancel_token: token)

      expect { chat.dispatch(tool_call("call_pre", "fake_tool", {})) }
        .to raise_error(Rubino::Interrupted)
      expect(ran).to be(false)
    end

    it "carries the cancel reason so an external teardown is not mislabeled as a user interrupt" do
      token.cancel!(reason: :external)

      described_class.install(chat, [agent_tool], ui: ui, event_bus: nil,
                                                  tool_executor: executor, cancel_token: token)

      raised = nil
      begin
        chat.dispatch(tool_call("call_ext", "fake_tool", {}))
      rescue Rubino::Interrupted => e
        raised = e
      end
      expect(raised.reason).to eq(:external)
    end

    it "runs the tool normally and returns its output when the token is NOT cancelled" do
      allow(repo).to receive(:record)
      agent_tool.output = "ok"

      described_class.install(chat, [agent_tool], ui: ui, event_bus: nil,
                                                  tool_executor: executor, cancel_token: token)

      expect(chat.dispatch(tool_call("call_ok", "fake_tool", {}))).to eq("ok")
    end
  end
end
