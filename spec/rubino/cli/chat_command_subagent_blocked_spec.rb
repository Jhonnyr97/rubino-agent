# frozen_string_literal: true

require "json"
require "stringio"

# F1-subagents — a dangerous tool blocked DIRECTLY in a headless one-shot exits
# 2 + stderr (#260). The SAME tool blocked INSIDE a `task` subagent used to exit
# 0 with empty stderr: the child latches its block on its OWN fresh UI::Null
# (nested_ui ⇒ Null off the CLI), which the parent — the adapter the one-shot
# CLI inspects — never sees. The block still held (the tool never ran), but the
# CLI reported false success, hiding the refusal from CI.
#
# Fix: a process-global HeadlessBlockLatch every UI::Null records into while a
# headless run is active, consulted by the one-shot exit check in addition to the
# parent adapter. These specs pin (1) the child→latch wiring and (2) that the
# one-shot exit propagates a latch-only block to exit 2 + a stderr notice.
RSpec.describe "F1-subagents headless fail-closed propagation" do
  describe Rubino::Output::HeadlessBlockLatch do
    before { described_class.reset! }
    after  { described_class.reset! }

    it "records a child UI::Null block when headless, surfacing it to the parent" do
      child_ui = Rubino::UI::Null.new

      # The child loop is fail-closed-blocked; it latches on ITS OWN adapter.
      Rubino.with_headless { child_ui.tool_blocked("blocked: shell (needs approval)") }

      # The parent adapter never saw it...
      parent_ui = Rubino::UI::Null.new
      expect(parent_ui.approval_blocked?).to be(false)
      # ...but the process-global latch did, so the CLI can still fail closed.
      expect(described_class.blocked?).to be(true)
      expect(described_class.messages).to include("blocked: shell (needs approval)")
    end

    it "does NOT record off the headless path (interactive/API surface their own way)" do
      Rubino::UI::Null.new.tool_blocked("blocked: write")
      expect(described_class.blocked?).to be(false)
    end

    it "reset! clears a stale block from a prior run" do
      Rubino.with_headless { Rubino::UI::Null.new.tool_blocked("blocked: edit") }
      expect(described_class.blocked?).to be(true)
      described_class.reset!
      expect(described_class.blocked?).to be(false)
    end
  end

  describe Rubino::CLI::ChatCommand do
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
      Rubino::Output::HeadlessBlockLatch.reset!
    end

    after { Rubino::Output::HeadlessBlockLatch.reset! }

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

    # A subagent-blocked run: the latch is set DURING the run (as the foreground
    # child would set it). We pre-stage the latch via a parent model that, when it
    # "runs", records a child block — simulating the subagent's discarded-Null
    # block reaching the global latch — then returns a clean answer (parent itself
    # never blocked). The CLI must still exit 2 with the notice on stderr.
    it "text one-shot: exits 2 with the notice when ONLY a subagent latched a block" do
      fake_llm.enqueue_text("I delegated that; the child could not run it.")
      # Simulate the child's block landing in the latch mid-run.
      allow(fake_llm).to receive(:stream).and_wrap_original do |orig, **kw|
        Rubino::Output::HeadlessBlockLatch.record("blocked: shell (subagent, needs approval)")
        orig.call(**kw)
      end

      stdout, stderr, status = run_oneshot("query" => "delegate a shell command")

      expect(stdout).to include("I delegated that")
      expect(status).to eq(2)
      expect(stderr).to include("blocked: shell")
    end

    it "json one-shot: emits is_error tool_blocked + exit 2 when only a subagent latched" do
      fake_llm.enqueue_text("delegated; blocked downstream")
      allow(fake_llm).to receive(:stream).and_wrap_original do |orig, **kw|
        Rubino::Output::HeadlessBlockLatch.record("blocked: shell (subagent)")
        orig.call(**kw)
      end

      stdout, stderr, status = run_oneshot("query" => "go", "output_format" => "json")

      obj = JSON.parse(stdout.each_line.map(&:strip).reject(&:empty?).last)
      expect(obj["is_error"]).to be(true)
      expect(obj["subtype"]).to eq("error_tool_blocked")
      expect(status).to eq(2)
      expect(stderr).to include("blocked: shell")
    end

    it "a clean run (no block anywhere) still exits 0" do
      fake_llm.enqueue_text("nothing blocked here")
      _stdout, _stderr, status = run_oneshot("query" => "hi")
      expect(status).to eq(0)
    end
  end
end
