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

    it "exits 0 when the write tool cleanly refuses an out-of-workspace path" do
      refused_path = "/etc/rubino-refusal-test-#{Process.pid}"
      fake_llm.enqueue_tool_call("write", { "file_path" => refused_path, "content" => "x" })
      fake_llm.enqueue_text("I can't write outside the workspace, so I left it alone.")

      # No SystemExit raised = exit status 0 for the process; the answer still
      # lands on stdout for the caller to consume.
      expect { described_class.new("query" => "write #{refused_path}").execute }
        .to output(/left it alone/).to_stdout

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
end
