# frozen_string_literal: true

# #215 — the documented notifications.command hook must fire on one-shot
# completion too. `run_oneshot` builds the runner with UI::Null and calls
# runner.run! directly, so it never reaches UI::CLI#turn_finished — the only
# place the notifier was wired. A scripted/headless `rubino prompt` / -q run
# is exactly what the command hook (RUBINO_EVENT=turn_finished) exists for, so
# the one-shot path drives the same notifier after the answer prints. The bell
# stays TTY-gated (self-suppresses into a pipe) — only the command hook does
# anything headless.
RSpec.describe Rubino::CLI::ChatCommand do
  describe "one-shot completion notification (#215)" do
    let(:db)       { test_database }
    let(:null_ui)  { Rubino::UI::Null.new }
    let(:fake_llm) { FakeLLMAdapter.new }

    let(:config) do
      mem    = Rubino::Config::Defaults.to_hash["memory"].merge("auto_extract" => false)
      skills = Rubino::Config::Defaults.to_hash["skills"].merge("auto_distill" => false)
      test_configuration(
        "memory" => mem,
        "skills" => skills,
        "notifications" => { "enabled" => true, "bell" => true,
                             "min_turn_seconds" => 0, "command" => hook_command }
      )
    end

    # A self-contained hook: append RUBINO_EVENT to a temp file. Detached +
    # async, so the example waits for the marker rather than asserting inline.
    let(:hook_log)     { File.join(Dir.tmpdir, "rubino-fx4-hook-#{Process.pid}-#{rand(1 << 16)}.log") }
    let(:hook_command) { %(sh -c 'printf "%s" "$RUBINO_EVENT" >> #{hook_log}') }

    before do
      allow(Rubino).to receive_messages(database: db, configuration: config)
      allow(Rubino::LLM::RubyLLMAdapter).to receive(:new).and_return(fake_llm)
      allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(true)
      Rubino.ui = null_ui
      FileUtils.rm_f(hook_log)
    end

    after { FileUtils.rm_f(hook_log) }

    it "fires the notifications.command hook with RUBINO_EVENT=turn_finished" do
      fake_llm.enqueue_text("done")

      expect do
        described_class.new("query" => "hi").execute
      rescue SystemExit => e
        raise "expected a clean one-shot run, but it exited with status #{e.status}"
      end.to output(/done/).to_stdout

      # The hook is spawned detached; poll briefly for the marker.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
      sleep(0.02) until File.exist?(hook_log) ||
                        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      expect(File.exist?(hook_log)).to be(true)
      expect(File.read(hook_log)).to eq("turn_finished")
    end
  end
end
