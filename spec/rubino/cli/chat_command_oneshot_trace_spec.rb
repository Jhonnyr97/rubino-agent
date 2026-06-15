# frozen_string_literal: true

require "json"
require "stringio"

# #418 follow-up — the non-interactive one-shot TEXT path (`rubino prompt` / -q /
# piped `chat`) now prints a default-on per-tool ACTIVITY TRACE: ONE concise line
# per tool completion (`· read a.rb`), routed to STDERR so the final answer on
# STDOUT stays clean by construction (x=$(rubino prompt …) captures ONLY the
# answer). --quiet/-Q silences the trace (machine-silent path); json/stream-json
# are unaffected (their structured tool events already live on stdout).
RSpec.describe Rubino::CLI::ChatCommand do
  let(:db)       { test_database }
  let(:null_ui)  { Rubino::UI::Null.new }
  let(:fake_llm) { FakeLLMAdapter.new }

  let(:config) do
    mem    = Rubino::Config::Defaults.to_hash["memory"].merge("auto_extract" => false)
    skills = Rubino::Config::Defaults.to_hash["skills"].merge("auto_distill" => false)
    test_configuration("memory" => mem, "skills" => skills)
  end

  before do
    allow(Rubino).to receive_messages(database: db, configuration: config)
    allow(Rubino::LLM::RubyLLMAdapter).to receive(:new).and_return(fake_llm)
    allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(true)
    Rubino.ui = null_ui
    Rubino::Modes.reset!
  end

  # Runs a one-shot, capturing stdout + stderr and any SystemExit status.
  def run_oneshot(opts)
    out = StringIO.new
    err = StringIO.new
    status = 0
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    begin
      described_class.new(opts).execute
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = orig_out
      $stderr = orig_err
    end
    [out.string, err.string, status]
  end

  describe "default text mode" do
    it "emits a per-tool trace line on STDERR and keeps STDOUT answer-only" do
      fake_llm.enqueue_tool_call("read", { "file_path" => "a.rb" },
                                 input_tokens: 5, output_tokens: 4)
      fake_llm.enqueue_text("done reading", input_tokens: 6, output_tokens: 3)

      stdout, stderr, status = run_oneshot(
        "query" => "read a.rb", "yolo" => true
      )

      # The answer — and ONLY the answer — is on stdout.
      expect(stdout.strip).to eq("done reading")
      expect(stdout).not_to include("· read")
      expect(stdout).not_to include("read a.rb")

      # The trace line is on stderr, in the shared `· name hint` vocabulary.
      expect(stderr).to include("· read a.rb")
      expect(status).to eq(0)
    end

    it "captures a clean answer with `2>/dev/null` semantics (stdout has no trace)" do
      fake_llm.enqueue_tool_call("read", { "file_path" => "README.md" },
                                 input_tokens: 5, output_tokens: 4)
      fake_llm.enqueue_text("the answer", input_tokens: 6, output_tokens: 3)

      stdout, = run_oneshot("query" => "go", "yolo" => true)

      # Dropping stderr (2>/dev/null) leaves a trace-free answer.
      lines = stdout.each_line.map(&:strip).reject(&:empty?)
      expect(lines).to eq(["the answer"])
    end
  end

  describe "--quiet / -Q" do
    it "silences the stderr trace (answer-only on stdout, no trace on stderr)" do
      fake_llm.enqueue_tool_call("read", { "file_path" => "a.rb" },
                                 input_tokens: 5, output_tokens: 4)
      fake_llm.enqueue_text("quiet answer", input_tokens: 6, output_tokens: 3)

      stdout, stderr, status = run_oneshot(
        "query" => "read a.rb", "yolo" => true, "quiet" => true
      )

      expect(stdout.strip).to eq("quiet answer")
      expect(stderr).not_to include("· read")
      expect(status).to eq(0)
    end
  end

  describe "json / stream-json are unaffected by the trace" do
    it "json: structured tool events stay on stdout, no human `· ` trace anywhere" do
      fake_llm.enqueue_tool_call("read", { "file_path" => "a.rb" },
                                 input_tokens: 5, output_tokens: 4)
      fake_llm.enqueue_text("json done", input_tokens: 6, output_tokens: 3)

      stdout, stderr, = run_oneshot(
        "query" => "go", "output_format" => "json", "yolo" => true
      )

      obj = JSON.parse(stdout.each_line.map(&:strip).reject(&:empty?).last)
      expect(obj["type"]).to eq("result")
      expect(obj["result"]).to eq("json done")
      expect(stdout).not_to include("· read")
      expect(stderr).not_to include("· read")
    end

    it "stream-json: tool_use lives on stdout, no human `· ` trace leaks" do
      fake_llm.enqueue_tool_call("read", { "file_path" => "a.rb" },
                                 input_tokens: 5, output_tokens: 4)
      fake_llm.enqueue_text("streamed", input_tokens: 6, output_tokens: 3)

      stdout, stderr, = run_oneshot(
        "query" => "go", "output_format" => "stream-json", "yolo" => true
      )

      expect(stdout).not_to include("· read")
      expect(stderr).not_to include("· read")
      objs = stdout.each_line.map(&:strip).reject(&:empty?).map { |l| JSON.parse(l) }
      assistant = objs.find { |o| o["type"] == "assistant" }
      tool_use = assistant["message"]["content"].find { |b| b["type"] == "tool_use" }
      expect(tool_use["name"]).to eq("read")
    end
  end
end
