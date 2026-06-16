# frozen_string_literal: true

require "json"
require "stringio"

# item 6 — ONESHOT-ACTIVE on the FAILURE path. The success / blocked / truncated
# one-shot paths all call runner.end_session!, but a TERMINAL exception
# (provider unreachable / unknown model / any uncaught error AFTER the session
# row was created) raised out of run! BEFORE that call — leaving the session
# status=active with a stale owner_pid until a future `sessions list` reaped it.
# The fix finalizes the session to `ended` in the one-shot ensure (the single
# chokepoint every exit path runs through), so the row is correct IMMEDIATELY.
#
# Driven through a REAL one-shot run (FakeLLM + real DB + real runner/session):
# the model raises a non-retryable AUTH error ("authentication failed"), which
# ErrorClassifier surfaces immediately (no retry storm), so the run terminates
# deterministically and the session row can be inspected.
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

  describe "finalizing the session on a terminal one-shot error (item 6)" do
    # A statusless "authentication failed" error → non-retryable AUTH, surfaced
    # immediately by ErrorClassifier (no ~80s retry storm), so the run fails
    # terminally and deterministically.
    def enqueue_terminal_error
      fake_llm.enqueue_error("authentication failed")
    end

    it "ends the session (status=ended) after a terminal error on the text path" do
      enqueue_terminal_error

      _stdout, stderr, status = run_oneshot("query" => "hi")

      # The run failed and exited non-zero with the error on stderr...
      expect(status).to eq(1)
      expect(stderr).to match(/authentication failed/i)

      # ...and the session row is ended IMMEDIATELY, not left active.
      rows = db.db[:sessions].all
      expect(rows).not_to be_empty
      expect(rows.map { |r| r[:status] }.uniq).to eq(["ended"])
    end

    it "ends the session (status=ended) after a terminal error on the json path" do
      enqueue_terminal_error

      _stdout, _stderr, status = run_oneshot("query" => "hi", "output_format" => "json")

      expect(status).to eq(1)
      rows = db.db[:sessions].all
      expect(rows).not_to be_empty
      expect(rows.map { |r| r[:status] }.uniq).to eq(["ended"])
    end
  end
end
