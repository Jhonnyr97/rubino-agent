# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Rubino::LLM::FakeProvider do
  # All specs in this file build a temp scenarios dir and inject it via
  # config to keep the fixtures self-contained.
  let(:tmp_dir) { Dir.mktmpdir }
  after { FileUtils.rm_rf(tmp_dir) }

  def write_scenario(name, events)
    File.write(File.join(tmp_dir, "#{name}.yml"), { "events" => events }.to_yaml)
  end

  def config_with(show_reasoning: false)
    test_configuration(
      "model" => { "provider" => "fake", "default" => "fake/happy-path",
                   "temperature" => 0.3, "context_length" => nil },
      "display" => { "streaming" => true, "show_reasoning" => show_reasoning },
      "fake_provider" => { "scenarios_dir" => tmp_dir }
    )
  end

  describe "#stream" do
    it "yields :content chunks and concatenates them into AdapterResponse#content" do
      write_scenario("happy-path", [
        { "type" => "content", "text" => "Hello, " },
        { "type" => "content", "text" => "world!" }
      ])
      adapter = described_class.new(model_id: "fake/happy-path", config: config_with)
      chunks = []
      response = adapter.stream(messages: [{ role: "user", content: "hi" }]) { |c| chunks << c }

      expect(chunks.map { |c| c[:type] }).to eq([:content, :content])
      expect(chunks.map { |c| c[:text] }).to eq(["Hello, ", "world!"])
      expect(response).to be_a(Rubino::LLM::AdapterResponse)
      expect(response.content).to eq("Hello, world!")
      expect(response.tool_calls).to be_empty
      expect(response.total_tokens).to eq(0)
    end

    it "gates :thinking chunks behind display.show_reasoning" do
      write_scenario("happy-path", [
        { "type" => "thinking", "text" => "reasoning..." },
        { "type" => "content",  "text" => "answer" }
      ])

      hidden = described_class.new(model_id: "fake/happy-path", config: config_with(show_reasoning: false))
      hidden_chunks = []
      hidden.stream(messages: [{ role: "user", content: "x" }]) { |c| hidden_chunks << c }
      expect(hidden_chunks.map { |c| c[:type] }).to eq([:content])

      shown = described_class.new(model_id: "fake/happy-path", config: config_with(show_reasoning: true))
      shown_chunks = []
      shown.stream(messages: [{ role: "user", content: "x" }]) { |c| shown_chunks << c }
      expect(shown_chunks.map { |c| c[:type] }).to eq([:thinking, :content])
    end

    it "treats a fresh user turn after an old tool result as a new turn (not post-tool)" do
      # Regression: post_tool_turn? used to fire on ANY tool message
      # anywhere in the conversation, which meant a multi-turn session
      # (turn 1 used a tool, turn 2 is a fresh user message) was
      # incorrectly served the closing "Done." instead of routing
      # through the scenario selector. The check now restricts to the
      # very last message.
      write_scenario("with-uploads", [
        { "type" => "content", "text" => "Received {{input}}." }
      ])
      adapter = described_class.new(model_id: "fake", config: config_with)
      response = adapter.stream(messages: [
        { role: "user",      content: "first request please upload" },
        { role: "assistant", content: "ok", tool_calls: [{ id: "1", name: "shell", arguments: {} }] },
        { role: "tool",      content: "old tool output", tool_call_id: "1", name: "shell" },
        { role: "assistant", content: "all done" },
        # Brand-new turn: user attaches a file with no text. This must
        # route to with-uploads, NOT collapse into the post-tool closing.
        { role: "user", content: "uploaded file: report.pdf" }
      ]) { |_c| }

      expect(response.content).to eq("Received uploaded file: report.pdf.")
    end

    it "ships with-artifacts scenario that calls write + attach_file in one turn" do
      # The shipped YAML drives the end-to-end artifact UX (the user asked
      # for the "agent reasons, talks, sends file" flow). Drift-checked here
      # so a future scenario edit doesn't silently drop attach_file.
      shipped = Rubino::LLM::ScenarioLoader.load(
        "with-artifacts",
        scenarios_dir: File.expand_path("../../../lib/rubino/llm/scenarios", __dir__)
      )
      tool_calls = shipped.select { |e| (e["type"] || e[:type]).to_s == "tool_call" }
      names = tool_calls.map { |t| t["name"] || t[:name] }

      expect(names).to eq(%w[write attach_file])
      attach_args = tool_calls.find { |t| (t["name"] || t[:name]) == "attach_file" }["arguments"]
      expect(attach_args["file_path"]).not_to be_empty
      expect(attach_args["filename"]).not_to be_empty
    end

    it "buffers tool_call events onto the final response with symbol keys and string-keyed arguments" do
      write_scenario("with-approvals", [
        { "type" => "content", "text" => "ok" },
        { "type" => "tool_call", "id" => "call_1", "name" => "shell",
          "arguments" => { "command" => "ls" } }
      ])
      adapter = described_class.new(model_id: "fake/with-approvals", config: config_with)
      chunks = []
      response = adapter.stream(messages: [{ role: "user", content: "x" }]) { |c| chunks << c }

      # Tool calls MUST NOT be yielded mid-stream — they live only on the final response.
      expect(chunks.map { |c| c[:type] }).to eq([:content])
      expect(response.has_tool_calls?).to be true
      tc = response.tool_calls.first
      expect(tc.keys).to contain_exactly(:id, :name, :arguments)
      expect(tc[:id]).to eq("call_1")
      expect(tc[:name]).to eq("shell")
      expect(tc[:arguments]).to eq("command" => "ls")
    end

    it "routes via the model_id 'fake/<name>' prefix without consulting the router" do
      write_scenario("pinned", [
        { "type" => "content", "text" => "from pinned" }
      ])
      adapter = described_class.new(model_id: "fake/pinned", config: config_with)
      response = adapter.stream(messages: [{ role: "user", content: "approve this" }]) { |_| }
      # The "approve" keyword would normally route to with-approvals, but the
      # model_id prefix wins.
      expect(response.content).to eq("from pinned")
    end

    it "falls back to the keyword router when model_id has no fake/ prefix" do
      write_scenario("failure", [
        { "type" => "content", "text" => "boom" }
      ])
      adapter = described_class.new(model_id: "fake", config: config_with)
      response = adapter.stream(messages: [{ role: "user", content: "this will crash" }]) { |_| }
      expect(response.content).to eq("boom")
    end

    it "stops mid-stream and returns the partial response when cancellation fires" do
      write_scenario("happy-path", [
        { "type" => "content",       "text" => "part 1" },
        { "type" => "delay_seconds", "value" => 0.01 },
        { "type" => "content",       "text" => "part 2" }
      ])
      token = Rubino::Interaction::CancelToken.new
      adapter = described_class.new(model_id: "fake/happy-path", config: config_with, cancel_token: token)

      chunks = []
      response = adapter.stream(messages: [{ role: "user", content: "x" }]) do |c|
        chunks << c
        token.cancel! if c[:type] == :content && chunks.size == 1
      end

      # First chunk landed; cancellation interrupted before "part 2".
      expect(chunks.map { |c| c[:text] }).to eq(["part 1"])
      expect(response.content).to eq("part 1")
      expect(response.tool_calls).to be_empty
    end

    it "preserves event ordering across mixed types" do
      write_scenario("happy-path", [
        { "type" => "thinking",  "text" => "T1" },
        { "type" => "content",   "text" => "C1" },
        { "type" => "thinking",  "text" => "T2" },
        { "type" => "content",   "text" => "C2" }
      ])
      adapter = described_class.new(model_id: "fake/happy-path", config: config_with(show_reasoning: true))
      sequence = []
      adapter.stream(messages: [{ role: "user", content: "x" }]) { |c| sequence << [c[:type], c[:text]] }

      expect(sequence).to eq([
        [:thinking, "T1"],
        [:content,  "C1"],
        [:thinking, "T2"],
        [:content,  "C2"]
      ])
    end
  end

  describe "#chat" do
    it "drives the scenario with a no-op block and returns the AdapterResponse" do
      write_scenario("happy-path", [
        { "type" => "content", "text" => "hi" },
        { "type" => "tool_call", "id" => "c1", "name" => "noop", "arguments" => {} }
      ])
      adapter = described_class.new(model_id: "fake/happy-path", config: config_with)
      response = adapter.chat(messages: [{ role: "user", content: "x" }])

      expect(response.content).to eq("hi")
      expect(response.tool_calls.first[:name]).to eq("noop")
    end
  end
end
