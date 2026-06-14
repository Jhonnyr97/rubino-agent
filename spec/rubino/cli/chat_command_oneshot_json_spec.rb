# frozen_string_literal: true

require "json"
require "stringio"

# #312 — machine-readable headless output. `rubino prompt --output-format
# json|stream-json` must emit ONLY JSON on stdout (logs/diagnostics to stderr),
# Claude-Code-aligned field names, and preserve the exit-code contract.
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

  # Runs a one-shot in the given format, capturing stdout + stderr and any
  # SystemExit status. Returns [stdout, stderr, status].
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

  describe "--output-format json" do
    it "emits ONE well-formed result object on stdout with the aligned fields" do
      fake_llm.enqueue_text("the final answer", input_tokens: 12, output_tokens: 8)

      stdout, stderr, status = run_oneshot(
        "query" => "hello", "output_format" => "json"
      )

      lines = stdout.each_line.map(&:strip).reject(&:empty?)
      expect(lines.length).to eq(1)

      obj = JSON.parse(lines.first)
      expect(obj["type"]).to eq("result")
      expect(obj["subtype"]).to eq("success")
      expect(obj["is_error"]).to be(false)
      expect(obj["result"]).to eq("the final answer")
      expect(obj["session_id"]).to be_a(String)
      expect(obj["exit_reason"]).to eq("end_turn")
      expect(obj["num_turns"]).to eq(1)
      expect(obj["usage"]).to include("input_tokens" => 12, "output_tokens" => 8,
                                      "cache_creation_input_tokens" => 0,
                                      "cache_read_input_tokens" => 0)
      expect(obj).to have_key("total_cost_usd")
      expect(obj).to have_key("model")
      expect(status).to eq(0)

      # No JSON noise on stderr.
      expect(stderr).not_to match(/"type"\s*:\s*"result"/)
    end

    it "treats --json as an alias for --output-format json" do
      fake_llm.enqueue_text("aliased", input_tokens: 1, output_tokens: 1)
      stdout, _stderr, status = run_oneshot("query" => "hi", "json" => true)
      obj = JSON.parse(stdout.each_line.map(&:strip).reject(&:empty?).first)
      expect(obj["result"]).to eq("aliased")
      expect(status).to eq(0)
    end
  end

  describe "--output-format stream-json" do
    it "emits valid JSONL: system(init) → assistant → user(tool_result) → result" do
      fake_llm.enqueue_tool_call("read", { "file_path" => "a.rb" },
                                 input_tokens: 5, output_tokens: 4)
      fake_llm.enqueue_text("done reading", input_tokens: 6, output_tokens: 3)

      stdout, _stderr, status = run_oneshot(
        "query" => "read a.rb", "output_format" => "stream-json", "yolo" => true
      )

      lines = stdout.each_line.map(&:strip).reject(&:empty?)
      # Every line is independently parseable (true JSONL).
      objs = lines.map { |l| JSON.parse(l) }

      expect(objs.first).to include("type" => "system", "subtype" => "init")
      expect(objs.first).to have_key("model")
      expect(objs.first["tools"]).to be_an(Array)

      types = objs.map { |o| o["type"] }
      expect(types.first).to eq("system")
      expect(types.last).to eq("result")
      expect(types).to include("assistant")
      expect(types).to include("user")

      assistant = objs.find { |o| o["type"] == "assistant" }
      tool_use = assistant["message"]["content"].find { |b| b["type"] == "tool_use" }
      expect(tool_use["name"]).to eq("read")

      user = objs.find { |o| o["type"] == "user" }
      expect(user["message"]["content"].first["type"]).to eq("tool_result")

      result = objs.last
      expect(result).to include("type" => "result", "is_error" => false)
      expect(status).to eq(0)
    end
  end

  describe "exit-code contract preserved" do
    let(:config) do
      mem      = Rubino::Config::Defaults.to_hash["memory"].merge("auto_extract" => false)
      skills   = Rubino::Config::Defaults.to_hash["skills"].merge("auto_distill" => false)
      approval = Rubino::Config::Defaults.to_hash["approvals"].merge("mode" => "manual")
      test_configuration("memory" => mem, "skills" => skills, "approvals" => approval)
    end

    it "emits is_error + non-zero exit when a tool is fail-closed blocked" do
      fake_llm.enqueue_tool_call("shell", { "command" => "touch /tmp/rubino-json-blocked" })
      fake_llm.enqueue_text("tried it")

      stdout, stderr, status = run_oneshot(
        "query" => "run shell", "output_format" => "json"
      )

      obj = JSON.parse(stdout.each_line.map(&:strip).reject(&:empty?).last)
      expect(obj["type"]).to eq("result")
      expect(obj["is_error"]).to be(true)
      expect(obj["subtype"]).to include("error")
      expect(status).not_to eq(0)
      # The human-readable block notice still goes to stderr.
      expect(stderr).to include("blocked: shell")
    end

    it "emits an error result + exit 1 when the run itself fails" do
      runner = instance_double(Rubino::Agent::Runner, session: { id: "x", model: "m" })
      allow(Rubino::Agent::Runner).to receive(:new).and_return(runner)
      allow(runner).to receive(:run!).and_raise(RuntimeError, "provider exploded")

      stdout, stderr, status = run_oneshot("query" => "hi", "output_format" => "json")

      obj = JSON.parse(stdout.each_line.map(&:strip).reject(&:empty?).last)
      expect(obj["is_error"]).to be(true)
      expect(obj["error"]).to include("message" => "provider exploded")
      expect(status).to eq(1)
      expect(stderr).to include("provider exploded")
    end

    it "rejects an unknown --output-format with a stderr message and non-zero exit" do
      _stdout, stderr, status = run_oneshot("query" => "hi", "output_format" => "yaml")
      expect(stderr).to include("invalid --output-format")
      expect(status).to eq(2)
    end
  end

  describe "text mode unchanged" do
    it "prints prose (no JSON) on stdout by default" do
      fake_llm.enqueue_text("just prose here")
      stdout, _stderr, status = run_oneshot("query" => "hi")
      expect(stdout).to include("just prose here")
      expect { JSON.parse(stdout.strip) }.to raise_error(JSON::ParserError)
      expect(status).to eq(0)
    end
  end
end
