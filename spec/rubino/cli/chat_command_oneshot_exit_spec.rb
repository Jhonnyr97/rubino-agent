# frozen_string_literal: true

# #116 — one-shot exit semantics. A CLEAN policy refusal (the write tool
# rejecting an out-of-workspace path) is expected behavior, not an error:
# the model receives the refusal as a tool result, answers anyway, the
# answer prints to stdout, and the process exits 0. Only a genuinely failed
# run (model/credential error, resume target missing) exits non-zero (#93).
# Documented in docs/commands.md ("Exit codes").
RSpec.describe Rubino::CLI::ChatCommand do
  describe "one-shot exit semantics (#116)" do
    let(:db)       { test_database }
    let(:null_ui)  { Rubino::UI::Null.new }
    let(:fake_llm) { FakeLLMAdapter.new }

    # Disable post-turn auto-extraction/distillation so the scripted FakeLLM
    # queue is consumed by the conversation alone (same setup as the e2e specs).
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
    end

    # --yolo so the write actually REACHES the tool (a headless write now needs
    # approval and would otherwise fail closed, #260) — this case is about the
    # TOOL's own out-of-workspace refusal being a clean exit-0, not the approval
    # gate. Reset Modes after so yolo doesn't leak into a later example.
    it "exits 0 when the write tool cleanly refuses an out-of-workspace path" do
      refused_path = "/etc/rubino-refusal-test-#{Process.pid}"
      fake_llm.enqueue_tool_call("write", { "file_path" => refused_path, "content" => "x" })
      fake_llm.enqueue_text("I can't write outside the workspace, so I left it alone.")

      # No SystemExit raised = exit status 0 for the process; the answer still
      # lands on stdout for the caller to consume. An UNEXPECTED exit is
      # rescued and turned into a real failure: letting SystemExit escape the
      # example kills the whole rspec process mid-suite (#163).
      expect do
        described_class.new("query" => "write #{refused_path}", "yolo" => true).execute
      rescue SystemExit => e
        raise "expected a clean exit-0 run, but ChatCommand exited with status #{e.status}"
      ensure
        Rubino::Modes.reset!
      end.to output(/left it alone/).to_stdout

      expect(File).not_to exist(refused_path)
    end

    it "still exits non-zero when the run itself fails" do
      runner = instance_double(Rubino::Agent::Runner)
      allow(Rubino::Agent::Runner).to receive(:new).and_return(runner)
      allow(runner).to receive(:run!).and_raise(RuntimeError, "simulated provider failure")

      status = nil
      expect do
        described_class.new("query" => "hi").execute
      rescue SystemExit => e
        status = e.status
      end.to output(/simulated provider failure/).to_stderr
      expect(status).to eq(1)
    end
  end

  # #260 — headless FAIL-CLOSED. A non-allowlisted shell command in a one-shot
  # run has no human to approve it (UI::Null), so it must be BLOCKED (not
  # auto-run, the old RCE foot-gun) and the process must exit NON-ZERO so
  # CI/automation fails loudly. --yolo is the explicit opt-in that runs it.
  describe "headless fail-closed for un-allowlisted shell (#260)" do
    let(:db)       { test_database }
    let(:null_ui)  { Rubino::UI::Null.new }
    let(:fake_llm) { FakeLLMAdapter.new }

    # approvals.mode: manual + require_confirmation_for_shell so a bare shell
    # command resolves to :ask — the exact production default this guards.
    let(:config) do
      mem      = Rubino::Config::Defaults.to_hash["memory"].merge("auto_extract" => false)
      skills   = Rubino::Config::Defaults.to_hash["skills"].merge("auto_distill" => false)
      approval = Rubino::Config::Defaults.to_hash["approvals"].merge("mode" => "manual")
      test_configuration("memory" => mem, "skills" => skills, "approvals" => approval)
    end

    let(:marker) { "/tmp/rubino-sec260-#{Process.pid}" }

    before do
      allow(Rubino).to receive_messages(database: db, configuration: config)
      allow(Rubino::LLM::RubyLLMAdapter).to receive(:new).and_return(fake_llm)
      allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(true)
      Rubino.ui = null_ui
      Rubino::Modes.reset!
      FileUtils.rm_f(marker)
    end

    after { FileUtils.rm_f(marker) }

    it "blocks the shell command, does NOT create the file, and exits non-zero" do
      fake_llm.enqueue_tool_call("shell", { "command" => "touch #{marker}" })
      fake_llm.enqueue_text("I tried to run the command.")

      status = nil
      expect do
        described_class.new("query" => "run a shell command").execute
      rescue SystemExit => e
        status = e.status
      end.to output(/blocked: shell.*needs approval but no interactive session/).to_stderr

      expect(status).not_to eq(0)
      expect(File).not_to exist(marker)
    end

    it "runs the shell command and exits 0 under --yolo (opt-in still works)" do
      fake_llm.enqueue_tool_call("shell", { "command" => "touch #{marker}" })
      fake_llm.enqueue_text("Done.")

      expect do
        described_class.new("query" => "run a shell command", "yolo" => true).execute
      rescue SystemExit => e
        raise "expected a clean exit-0 run under --yolo, got status #{e.status}"
      end.to output(/Done\./).to_stdout

      expect(File).to exist(marker)
    end
  end
end
