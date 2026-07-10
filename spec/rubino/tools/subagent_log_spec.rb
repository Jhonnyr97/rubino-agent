# frozen_string_literal: true

RSpec.describe Rubino::Tools::SubagentLog do
  let(:sa_id)      { "sa_test123" }
  let(:session_id) { "sess_abc456" }
  let(:tmpdir)     { Dir.mktmpdir("subagent_log_spec") }
  let(:workspace_root) { File.join(tmpdir, "workspace") }
  let(:rubino_dir)     { File.join(workspace_root, ".rubino") }

  before do
    # Stub Workspace.primary_root so the log file lands under our tmpdir
    # instead of the real user workspace.
    allow(Rubino::Workspace).to receive(:primary_root).and_return(workspace_root)
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  # ── write_event ──────────────────────────────────────────────────────

  describe "#write_event" do
    let(:log) { described_class.new(sa_id: sa_id, session_id: session_id) }

    after { log.close }

    it "writes a valid JSON object with required fields" do
      log.write_event("subagent_started", subagent: "explore", prompt: "hello")

      lines = File.readlines(log.path)
      expect(lines.size).to eq(1)

      event = JSON.parse(lines.first)
      expect(event["type"]).to        eq("subagent_started")
      expect(event["uuid"]).to        match(/\A[a-f0-9-]{36}\z/)
      expect(event["timestamp"]).to   match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
      expect(event["sessionId"]).to   eq(session_id)
      expect(event["taskId"]).to      eq(sa_id)
      expect(event["subagent"]).to    eq("explore")
      expect(event["prompt"]).to      eq("hello")
    end

    it "sync-flushes every write so data survives a crash" do
      log.write_event("subagent_started", subagent: "explore")

      # After a single write the file must already contain the line on disk
      # (no buffering delay). We read it back immediately to confirm.
      content = File.read(log.path)
      expect(content).to include("\"type\":\"subagent_started\"")
    end

    it "writes one JSON object per line (JSONL)" do
      log.write_event("user", message: "a")
      log.write_event("assistant", message: "b")

      lines = File.readlines(log.path)
      expect(lines.size).to eq(2)

      # Each line is valid JSON
      lines.each { |line| expect { JSON.parse(line) }.not_to raise_error }
    end

    it "silently no-ops after close" do
      log.close
      # Should not raise, and should not write anything
      log.write_event("user", message: "after close")
      # Reopen to verify nothing extra was appended
      expect(File.readlines(log.path).size).to eq(0)
    end
  end

  # ── path ─────────────────────────────────────────────────────────────

  describe "#path" do
    it "is built under <workspace>/.rubino/sessions/<id>/tasks/<id>.jsonl" do
      log = described_class.new(sa_id: sa_id, session_id: session_id)
      expected = File.join(workspace_root, ".rubino", "sessions", session_id, "tasks", "#{sa_id}.jsonl")
      expect(log.path).to eq(expected)
      log.close
    end

    it "creates the parent directories" do
      log = described_class.new(sa_id: sa_id, session_id: session_id)
      expect(File.directory?(File.dirname(log.path))).to be true
      log.close
    end
  end

  # ── close ────────────────────────────────────────────────────────────

  describe "#close" do
    it "is idempotent — multiple closes don't raise" do
      log = described_class.new(sa_id: sa_id, session_id: session_id)
      log.write_event("subagent_started", subagent: "explore")

      log.close
      expect { log.close }.not_to raise_error
      expect { log.close }.not_to raise_error
    end

    it "tolerates a nil io (failed open)" do
      # Simulate a failed file open by passing an impossible path, then
      # construct the instance manually so it has a nil @io.
      log = described_class.allocate
      log.instance_variable_set(:@sa_id, sa_id)
      log.instance_variable_set(:@session_id, session_id)
      log.instance_variable_set(:@path, "/dev/null/impossible/path/subagent_log.jsonl")
      log.instance_variable_set(:@io, nil)
      log.instance_variable_set(:@closed, false)

      expect { log.close }.not_to raise_error
    end
  end

  # ── TeeStore ─────────────────────────────────────────────────────────

  describe Rubino::Tools::SubagentLog::TeeStore do
    # A lightweight test double that tracks calls without touching the DB
    let(:real_store) do
      double("Session::Store").tap do |d|
        allow(d).to receive(:create)
        allow(d).to receive(:token_sum).and_return(500)
      end
    end
    let(:subagent_log) { Rubino::Tools::SubagentLog.new(sa_id: sa_id, session_id: session_id) }
    let(:tee)          { described_class.new(real_store, subagent_log) }

    after { subagent_log.close }

    def last_log_event
      lines = File.readlines(subagent_log.path)
      return nil if lines.empty?

      JSON.parse(lines.last)
    end

    it "calls the real store AND tees a user event" do
      allow(real_store).to receive(:create)

      tee.create(session_id: sa_id, role: "user", content: "hello world")

      expect(real_store).to have_received(:create).with(
        session_id: sa_id, role: "user", content: "hello world"
      )
      event = last_log_event
      expect(event["type"]).to eq("user")
      expect(event.dig("message", "role")).to eq("user")
      expect(event.dig("message", "content")).to eq("hello world")
    end

    it "tees an assistant event with tool_use blocks from metadata" do
      metadata = {
        tool_calls: [
          { id: "call_1", name: "shell", input: { command: "ls" } }
        ],
        token_count: 42
      }

      tee.create(session_id: sa_id, role: "assistant", content: "Let me list files",
                 metadata: metadata)

      event = last_log_event
      expect(event["type"]).to eq("assistant")
      blocks = event.dig("message", "content")
      expect(blocks).to be_an(Array)
      expect(blocks.size).to eq(2) # text + tool_use

      text_block = blocks.find { |b| b["type"] == "text" }
      expect(text_block["text"]).to eq("Let me list files")

      tool_block = blocks.find { |b| b["type"] == "tool_use" }
      expect(tool_block["id"]).to eq("call_1")
      expect(tool_block["name"]).to eq("shell")
      expect(tool_block["input"]).to eq("command" => "ls")

      usage = event.dig("message", "usage")
      expect(usage).to eq("total_tokens" => 42)
    end

    it "tees an assistant event without tool_calls (text-only)" do
      tee.create(session_id: sa_id, role: "assistant", content: "Done.",
                 metadata: {})

      event = last_log_event
      expect(event["type"]).to eq("assistant")
      blocks = event.dig("message", "content")
      expect(blocks.size).to eq(1)
      expect(blocks.first["type"]).to eq("text")
      expect(blocks.first["text"]).to eq("Done.")
    end

    it "tees a tool_result event with tool_use_id, tool_name, output" do
      tee.create(session_id: sa_id, role: "tool", content: "file list output",
                 tool_call_id: "call_abc", tool_name: "shell")

      event = last_log_event
      expect(event["type"]).to eq("tool_result")
      expect(event["tool_use_id"]).to eq("call_abc")
      expect(event["tool_name"]).to eq("shell")
      expect(event["output"]).to eq("file list output")
    end

    it "delegates unknown methods to the real store" do
      allow(real_store).to receive(:token_sum).and_return(500)

      result = tee.token_sum(sa_id)
      expect(result).to eq(500)
    end

    it "responds_to? methods on the real store" do
      expect(tee.respond_to?(:token_sum)).to be true
      expect(tee.respond_to?(:nonexistent_method_xyz)).to be false
    end
  end
end
