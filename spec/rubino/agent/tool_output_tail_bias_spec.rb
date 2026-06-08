# frozen_string_literal: true

# Tool output truncation must be tail-biased: when a shell command or a grep
# call produces 200k bytes, the bytes that matter are at the end (exit code,
# error message, "N failures" line). Head-only truncation drops exactly the
# part we need. The middle marker tells the model what was elided so it can
# narrow the next call instead of assuming the missing bytes were uniform.
RSpec.describe Rubino::Agent::ToolExecutor do
  let(:registry)  { class_double(Rubino::Tools::Registry) }
  let(:policy)    { instance_double(Rubino::Security::ApprovalPolicy) }
  let(:ui)        { Rubino::UI::Null.new }
  let(:config)    { Rubino.configuration }
  let(:repo)      { instance_double(Rubino::Tools::ToolCallRepository, record: true) }

  let(:tool) do
    Class.new do
      attr_accessor :output, :cancel_token, :read_tracker, :stream_chunk
      def name = "fake_tool"
      def description = ""
      def input_schema = {}
      def risk_level = :low
      def risky? = false
      def call(_args) = @output
    end.new
  end

  let(:executor) do
    described_class.new(
      registry:             registry,
      approval_policy:      policy,
      ui:                   ui,
      config:               config,
      tool_call_repository: repo
    )
  end

  # Sandbox the home dir: truncation spills the full output to
  # <home>/tool-results/<call_id>.txt, so point home at a tmp dir to keep the
  # real ~/.rubino clean during tests.
  let(:spill_home) { Dir.mktmpdir("spill_home") }
  after { FileUtils.rm_rf(spill_home) }

  before do
    allow(registry).to receive(:find).with("fake_tool").and_return(tool)
    allow(policy).to receive(:decide).and_return(:allow)
    allow(Rubino).to receive(:home_path).and_return(spill_home)
  end

  describe "byte-level tail bias" do
    it "keeps a small head, the marker, and the tail when above max_bytes" do
      allow(config).to receive(:tool_output_max_bytes).and_return(1_000)
      allow(config).to receive(:tool_output_max_lines).and_return(10_000)
      tool.output = "HEAD#{'x' * 5_000}TAIL"

      result = executor.execute(name: "fake_tool", arguments: {}, call_id: "c1")

      expect(result.output).to start_with("HEAD")
      expect(result.output).to end_with("TAIL")
      expect(result.output).to include("bytes elided")
      expect(result.output.bytesize).to be <= 1_100 # small slack for marker
    end

    it "does not truncate when text is within budget" do
      allow(config).to receive(:tool_output_max_bytes).and_return(1_000)
      allow(config).to receive(:tool_output_max_lines).and_return(10_000)
      tool.output = "short"
      result = executor.execute(name: "fake_tool", arguments: {}, call_id: "c2")
      expect(result.output).to eq("short")
    end

    it "preserves the [Exit code: N] suffix shell appends at the tail" do
      allow(config).to receive(:tool_output_max_bytes).and_return(2_000)
      allow(config).to receive(:tool_output_max_lines).and_return(10_000)
      noise = "verbose noise\n" * 500
      tool.output = "#{noise}\n[Exit code: 1]"

      result = executor.execute(name: "fake_tool", arguments: {}, call_id: "c3")
      expect(result.output).to include("[Exit code: 1]")
    end
  end

  describe "spill-to-file on overflow" do
    it "writes the FULL output to tool-results/<call_id>.txt and points the marker at it" do
      allow(config).to receive(:tool_output_max_bytes).and_return(1_000)
      allow(config).to receive(:tool_output_max_lines).and_return(10_000)
      full = "HEAD#{'x' * 5_000}TAIL"
      tool.output = full

      result = executor.execute(name: "fake_tool", arguments: {}, call_id: "spill1")

      spill_file = File.join(spill_home, "tool-results", "spill1.txt")
      expect(File).to exist(spill_file)
      expect(File.read(spill_file)).to eq(full)                 # complete, un-elided
      expect(result.output).to include(spill_file)              # marker references it
      expect(result.output).to include("read it with offset/limit")
    end

    it "does not spill when output is within budget" do
      allow(config).to receive(:tool_output_max_bytes).and_return(1_000)
      allow(config).to receive(:tool_output_max_lines).and_return(10_000)
      tool.output = "short"
      executor.execute(name: "fake_tool", arguments: {}, call_id: "nospill")
      expect(Dir.exist?(File.join(spill_home, "tool-results"))).to be(false).or(
        satisfy { |_| Dir[File.join(spill_home, "tool-results", "*")].empty? }
      )
    end
  end

  describe "line-level tail bias" do
    it "elides middle lines and keeps both ends" do
      allow(config).to receive(:tool_output_max_bytes).and_return(10_000_000)
      allow(config).to receive(:tool_output_max_lines).and_return(20)
      tool.output = (1..100).map { |i| "line-#{i}" }.join("\n")

      result = executor.execute(name: "fake_tool", arguments: {}, call_id: "c4")

      expect(result.output).to include("line-1")
      expect(result.output).to include("line-100")
      expect(result.output).to include("lines elided")
      # The truly middle lines (40..60) must NOT be present.
      expect(result.output).not_to include("line-50")
    end
  end
end
