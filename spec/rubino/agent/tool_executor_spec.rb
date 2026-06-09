# frozen_string_literal: true

RSpec.describe Rubino::Agent::ToolExecutor do
  subject(:executor) do
    described_class.new(registry: registry, approval_policy: policy, ui: ui,
                        config: config, tool_call_repository: repo)
  end

  let(:tool) do
    Class.new(Rubino::Tools::Base) do
      def name = "fake_tool"
      def description = "fake"
      def input_schema = { type: "object" }
      def risk_level = :low
      attr_writer :output

      def call(_args)
        @output.nil? ? "ok" : @output
      end
    end.new
  end

  let(:registry) { double("Registry", find: tool) }
  let(:policy)   { double("ApprovalPolicy") }
  let(:ui)       { double("UI", confirm: true) }
  let(:repo)     { double("Repo", record: true) }
  let(:config)   { Rubino.configuration }

  # Overflowing output spills the full text to <home>/tool-results/<id>.txt;
  # sandbox home so tests don't write into the real ~/.rubino.
  let(:spill_home) { Dir.mktmpdir("spill_home") }

  after { FileUtils.rm_rf(spill_home) }
  before { allow(Rubino).to receive(:home_path).and_return(spill_home) }

  describe "approval decisions" do
    it "records the call and runs the tool when policy allows" do
      allow(policy).to receive(:decide).and_return(:allow)
      expect(repo).to receive(:record).with(hash_including(status: "completed"))
      result = executor.execute(name: "fake_tool", arguments: { "x" => 1 }, call_id: "c1")
      expect(result.output).to eq("ok")
    end

    it "audits denied calls when policy returns :deny (issue #7, #17)" do
      allow(policy).to receive(:decide).and_return(:deny)
      expect(repo).to receive(:record).with(hash_including(status: "denied", error: "policy-denied"))
      result = executor.execute(name: "fake_tool", arguments: {}, call_id: "c2")
      expect(result.denied?).to be true
    end

    it "audits denied calls when the user rejects an :ask prompt" do
      allow(policy).to receive(:decide).and_return(:ask)
      allow(ui).to receive(:confirm).and_return(false)
      expect(repo).to receive(:record).with(hash_including(status: "denied", error: "user-denied"))
      result = executor.execute(name: "fake_tool", arguments: {}, call_id: "c3")
      expect(result.denied?).to be true
    end

    it "passes the arguments to the approval policy so patterns can match (#17)" do
      allow(policy).to receive(:decide).and_return(:allow)
      expect(policy).to receive(:decide).with(tool, arguments: { "x" => 1 })
      executor.execute(name: "fake_tool", arguments: { "x" => 1 }, call_id: "c4")
    end
  end

  # Regression: arguments.inspect on multi-line values collapsed everything
  # into one giant line, the terminal cropped at 80 columns, and the user
  # approved a "ls -la" they could see while the model had actually sent
  # `ls -la; rm -rf $HOME`. Each arg is now laid out on its own line and
  # multi-line values get a "[… N more line(s)]" tag so silence can't hide
  # the tail.
  # Regression: --yolo (approvals.mode: "skip") used to silently auto-run
  # every tool. The user pressed Enter and the model could fire shell or
  # write without any visual signal. Now risky tools emit a "⚡ yolo:"
  # warning right before execution so silence can't mask intent.
  describe "yolo mode visibility" do
    before do
      allow(policy).to receive(:decide).and_return(:allow)
      # The general stub goes FIRST so the specific one overrides it for
      # ("approvals", "mode"); RSpec resolves the most-specific match last.
      allow(config).to receive(:dig).and_call_original
      allow(config).to receive(:dig).with("approvals", "mode").and_return("skip")
    end

    it "warns before running a risky tool in skip mode" do
      # fake_tool defined at the top of this file is :low risk; build a :high one
      risky = Class.new(Rubino::Tools::Base) do
        def name = "shell"
        def description = "x"
        def input_schema = {}
        def risk_level = :high
        def call(_) = "out"
      end.new
      allow(registry).to receive(:find).and_return(risky)

      expect(ui).to receive(:warning).with(a_string_matching(/yolo.*shell.*command=ls/))
      executor.execute(name: "shell", arguments: { "command" => "ls" }, call_id: "c1")
    end

    it "stays quiet for low-risk tools in skip mode" do
      expect(ui).not_to receive(:warning)
      executor.execute(name: "fake_tool", arguments: {}, call_id: "c2")
    end
  end

  # Regression: a streaming tool (ShellTool) emits its stdout line by line via
  # #tool_chunk AND returns a `body:` block (Util::Output.preview of the same
  # stdout). The executor used to render BOTH, so every output line appeared
  # twice in the timeline. When the tool streamed, the body must be suppressed.
  describe "streamed tool output is not also rendered as a body" do
    subject(:streaming_executor) do
      described_class.new(registry: streaming_registry, approval_policy: policy,
                          ui: streaming_ui, config: config, tool_call_repository: repo)
    end

    let(:streaming_tool) do
      Class.new(Rubino::Tools::Base) do
        def name = "fake_stream"
        def description = "fake"
        def input_schema = { type: "object" }
        def risk_level = :low

        def call(_args)
          emit_chunk("13\n")
          { output: "13\n", body: "13", body_kind: :plain }
        end
      end.new
    end

    let(:streaming_registry) { double("Registry", find: streaming_tool) }
    let(:streaming_ui) do
      double("UI", confirm: true, tool_started: nil, tool_finished: nil, tool_chunk: nil, tool_body: nil)
    end

    before { allow(policy).to receive(:decide).and_return(:allow) }

    it "streams chunks but does NOT re-render the body for a streaming tool" do
      expect(streaming_ui).to receive(:tool_chunk).with("fake_stream", "13\n")
      expect(streaming_ui).not_to receive(:tool_body)
      streaming_executor.execute(name: "fake_stream", arguments: {}, call_id: "s1")
    end

    it "still renders the body for a NON-streaming tool that returns one" do
      non_streaming = Class.new(Rubino::Tools::Base) do
        def name = "fake_body"
        def description = "fake"
        def input_schema = { type: "object" }
        def risk_level = :low
        def call(_args) = { output: "x", body: "preview", body_kind: :plain }
      end.new
      allow(streaming_registry).to receive(:find).and_return(non_streaming)
      expect(streaming_ui).to receive(:tool_body).with("preview", kind: :plain)
      expect(streaming_ui).not_to receive(:tool_chunk)
      streaming_executor.execute(name: "fake_body", arguments: {}, call_id: "s2")
    end
  end

  describe "tool.progress heartbeats on the bus (SSE idle watchdog)" do
    # A long, silent tool that emits several stream chunks. In API mode these
    # must reach the event bus as TOOL_PROGRESS so the SSE stream isn't silent
    # for minutes and the idle watchdog doesn't reap a busy-but-quiet run.
    subject(:bus_executor) do
      described_class.new(registry: bus_reg, approval_policy: policy,
                          ui: bus_ui, config: config, tool_call_repository: repo,
                          event_bus: bus)
    end

    let(:chatty_tool) do
      Class.new(Rubino::Tools::Base) do
        def name = "chatty"
        def description = "fake"
        def input_schema = { type: "object" }
        def risk_level = :low

        def call(_args)
          5.times { |i| emit_chunk("chunk #{i}\n") }
          "done"
        end
      end.new
    end
    let(:bus)     { Rubino::Interaction::EventBus.new }
    let(:bus_reg) { double("Registry", find: chatty_tool) }
    let(:bus_ui)  { double("UI", confirm: true, tool_started: nil, tool_finished: nil) }

    before { allow(policy).to receive(:decide).and_return(:allow) }

    it "emits TOOL_PROGRESS on the bus even when the UI has no tool_chunk sink" do
      progress = []
      bus.on(Rubino::Interaction::Events::TOOL_PROGRESS) { |p| progress << p }
      bus_executor.execute(name: "chatty", arguments: {}, call_id: "p1")
      # Throttled to one per interval; the first chunk always emits, the rest
      # fall inside the window. At minimum the first heartbeat must flow.
      expect(progress).not_to be_empty
      expect(progress.first[:name]).to eq("chatty")
      expect(progress.first[:chunk]).to include("chunk 0")
    end

    it "throttles back-to-back chunks so a chatty tool doesn't flood the store" do
      progress = []
      bus.on(Rubino::Interaction::Events::TOOL_PROGRESS) { |p| progress << p }
      bus_executor.execute(name: "chatty", arguments: {}, call_id: "p2")
      # 5 chunks fired in a tight loop (well under TOOL_PROGRESS_INTERVAL) →
      # only the first crosses the throttle.
      expect(progress.length).to eq(1)
    end
  end

  describe "approval question formatting" do
    it "lays each argument on its own line" do
      question = executor.send(:approval_question, tool,
                               { "file_path" => "a.rb", "mode" => "w" })
      expect(question).to include("file_path: a.rb")
      expect(question).to include("mode: w")
      expect(question.lines.size).to be >= 3
    end

    it "tags the count of dropped lines when a value is multi-line" do
      cmd = (1..10).map { |i| "echo #{i}" }.join("\n")
      question = executor.send(:approval_question, tool, { "command" => cmd })
      expect(question).to include("echo 1")
      expect(question).to include("echo 5")
      expect(question).to include("[… 5 more line(s)]")
      expect(question).not_to include("echo 6")
    end

    it "truncates very long single-line values with an explicit ellipsis" do
      long = "a" * 300
      question = executor.send(:approval_question, tool, { "blob" => long })
      expect(question).to include("…")
      expect(question.length).to be < 400
    end
  end

  describe "UTF-8 safe truncation (#19)" do
    before { allow(policy).to receive(:decide).and_return(:allow) }

    it "does not produce invalid bytes when truncating mid-character" do
      # 4-byte emoji repeated past the byte cap → would split mid-char with naked byteslice
      allow(config).to receive(:tool_output_max_bytes).and_return(10)
      allow(config).to receive(:tool_output_max_lines).and_return(1_000)
      tool.output = "🚀" * 20 # 4 bytes × 20 = 80 bytes

      result = executor.execute(name: "fake_tool", arguments: {}, call_id: "c5")
      expect(result.output.valid_encoding?).to be true
      expect(result.output).to include("truncated at 10 bytes")
    end
  end
end
