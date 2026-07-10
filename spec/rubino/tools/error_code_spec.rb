# frozen_string_literal: true

# error_code is the structured failure-mode tag that lives next to the
# human-facing output string. Today only a handful of error sites populate
# it (shell deny-list, read on binary, edit/multi_edit read-gate), but the
# plumbing must be in place end-to-end so future contract tests and UI
# badges can branch on it without parsing strings.
RSpec.describe Rubino::Tools::Result do
  describe "::success" do
    it "carries an optional error_code symbol" do
      r = described_class.success(
        name: "shell", call_id: "c1", output: "Error: ...", error_code: :timeout
      )
      expect(r.error_code).to eq(:timeout)
      expect(r.status).to eq(:success) # error_code is orthogonal to status
    end

    it "defaults error_code to nil when not provided" do
      r = described_class.success(name: "read", call_id: "c1", output: "ok")
      expect(r.error_code).to be_nil
    end
  end

  describe "::error" do
    it "accepts an error_code symbol" do
      r = described_class.error(name: "patch", call_id: "c1",
                                error: "context mismatch", error_code: :context_mismatch)
      expect(r.error_code).to eq(:context_mismatch)
    end
  end
end

RSpec.describe Rubino::Agent::ToolExecutor do
  let(:registry)  { class_double(Rubino::Tools::Registry) }
  let(:policy)    { instance_double(Rubino::Security::ApprovalPolicy) }
  let(:ui)        { Rubino::UI::Null.new }
  let(:config)    { Rubino.configuration }
  let(:repo)      { instance_double(Rubino::Tools::ToolCallRepository, record: true) }

  let(:tool) do
    Class.new do
      attr_accessor :payload, :cancel_token, :read_tracker, :stream_chunk

      def name = "fake_tool"
      def description = ""
      def input_schema = {}
      def risk_level = :low
      def risky? = false
      def call(_args) = @payload
    end.new
  end

  let(:executor) do
    described_class.new(
      registry: registry,
      approval_policy: policy,
      ui: ui,
      config: config,
      tool_call_repository: repo
    )
  end

  before do
    allow(registry).to receive(:find).with("fake_tool").and_return(tool)
    allow(policy).to receive(:decide).and_return(:allow)
  end

  describe "propagating :error_code from hash returns" do
    it "lifts a symbol into the Result.error_code" do
      tool.payload = { output: "Error: x", error_code: :context_mismatch }
      r = executor.execute(name: "fake_tool", arguments: {}, call_id: "c1")
      expect(r.error_code).to eq(:context_mismatch)
    end

    it "tolerates a string key" do
      tool.payload = { "output" => "Error: x", "error_code" => "timeout" }
      r = executor.execute(name: "fake_tool", arguments: {}, call_id: "c2")
      expect(r.error_code).to eq(:timeout)
    end

    it "is nil when the tool returns a plain string" do
      tool.payload = "ok"
      r = executor.execute(name: "fake_tool", arguments: {}, call_id: "c3")
      expect(r.error_code).to be_nil
    end
  end

  # Redaction now lives ONLY at this chokepoint (removed from the tools), so the
  # end-to-end "a secret in tool output gets masked" guarantee is verified here,
  # driving a tool through the executor — not per-tool in isolation. The masking
  # algorithm itself is covered by redactor_spec; each tool's declared profile
  # by its own spec.
  describe "redaction chokepoint" do
    before { Rubino::Security::Redactor.reset! }
    after  { Rubino::Security::Redactor.reset! }

    it "masks a credential value in the tool's model-facing output (fail-safe default profile)" do
      tool.payload = { output: "key=ghp_abcdefghijklmnop1234" }
      r = executor.execute(name: "fake_tool", arguments: {}, call_id: "red1")
      expect(r.output).not_to include("ghp_abcdefghijklmnop1234")
      expect(r.output).to include("ghp_ab...1234")
    end

    it "leaves output untouched for a tool whose redaction_profile is :none" do
      none_tool = Class.new do
        attr_accessor :payload

        def self.redaction_profile = :none
        def name = "none_tool"
        def description = ""
        def input_schema = {}
        def risk_level = :low
        def risky? = false
        def call(_args) = @payload
      end.new
      none_tool.payload = { output: "key=ghp_abcdefghijklmnop1234" }
      allow(registry).to receive(:find).with("none_tool").and_return(none_tool)
      r = executor.execute(name: "none_tool", arguments: {}, call_id: "red2")
      expect(r.output).to include("ghp_abcdefghijklmnop1234")
    end
  end
end
