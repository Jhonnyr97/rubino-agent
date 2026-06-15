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

    # #335a — a one-shot SIGINT mid-turn used to raise a bare uncaught Interrupt
    # (a 60-line backtrace from net/protocol). The one-shot path now traps
    # SIGINT into a cooperative cancel; the Rubino::Interrupted that propagates
    # — OR a bare Interrupt that landed deep in a blocking read before the next
    # chunk checkpoint — exits CLEANLY with the conventional 130, no backtrace.
    [["cooperative Rubino::Interrupted", Rubino::Interrupted],
     ["bare Interrupt (deep in a blocking read)", Interrupt]].each do |label, klass|
      it "exits 130 with a clean notice (no backtrace) on #{label}" do
        runner = instance_double(Rubino::Agent::Runner)
        allow(Rubino::Agent::Runner).to receive(:new).and_return(runner)
        allow(runner).to receive(:cancel!)
        allow(runner).to receive(:run!).and_raise(klass)
        allow(runner).to receive(:session).and_return({ id: "s1" })

        status = nil
        expect do
          described_class.new("query" => "hi").execute
        rescue SystemExit => e
          status = e.status
        end.to output(/interrupted/).to_stderr

        # Exit 130 (clean), never the raw uncaught backtrace exit the bug showed.
        expect(status).to eq(130)
      end
    end

    it "emits a well-formed interrupted JSON result and exits 130 (--json)" do
      runner = instance_double(Rubino::Agent::Runner)
      allow(Rubino::Agent::Runner).to receive(:new).and_return(runner)
      allow(runner).to receive(:cancel!)
      allow(runner).to receive(:run!).and_raise(Rubino::Interrupted)
      allow(runner).to receive(:session).and_return({ id: "s1", model: "fake-model" })

      status = nil
      # The interrupted result is a well-formed {type:"result", …} object whose
      # body carries the interrupt — assert it on stdout, exit 130 alongside.
      expect do
        described_class.new("query" => "hi", "json" => true).execute
      rescue SystemExit => e
        status = e.status
      end.to output(/"type":"result".*interrupt/i).to_stdout

      expect(status).to eq(130)
    end
  end

  # P2-H3 — empty/whitespace one-shot input must NOT be dispatched to the
  # model (an empty `-q`/`prompt ""` is truthy in Ruby, so it used to spend a
  # real API turn). Mirror interactive mode's `next if input.strip.empty?`:
  # a clear "no prompt provided" message on stderr + non-zero exit, BEFORE any
  # runner is built or the model is called.
  describe "empty-input guard on the one-shot path (P2-H3)" do
    before do
      # No FakeLLM and no credential stub — the guard must fire well before any
      # model/credential code is reached. A built runner would prove the guard
      # failed, so spy on the constructor and assert it never ran.
      allow(Rubino::Agent::Runner).to receive(:new).and_call_original
    end

    [["empty string", ""], ["whitespace only", "   \t\n"]].each do |label, blank|
      it "rejects #{label} with a stderr message, non-zero exit, and no runner built" do
        status = nil
        expect do
          described_class.new("query" => blank).execute
        rescue SystemExit => e
          status = e.status
        end.to output(/no prompt provided/).to_stderr

        expect(status).to eq(1)
        expect(Rubino::Agent::Runner).not_to have_received(:new)
      end
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

    # approvals.mode: manual + confirm_policy: confirm_all so a bare shell
    # command resolves to :ask — this guards the headless fail-closed floor
    # (#260) independent of the default prompt policy (now dangerous_only, #409,
    # under which `touch` would auto-allow). confirm_all is the hardening opt-in.
    let(:config) do
      mem      = Rubino::Config::Defaults.to_hash["memory"].merge("auto_extract" => false)
      skills   = Rubino::Config::Defaults.to_hash["skills"].merge("auto_distill" => false)
      approval = Rubino::Config::Defaults.to_hash["approvals"].merge("mode" => "manual")
      security = Rubino::Config::Defaults.to_hash["security"].merge("confirm_policy" => "confirm_all")
      test_configuration("memory" => mem, "skills" => skills, "approvals" => approval, "security" => security)
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
