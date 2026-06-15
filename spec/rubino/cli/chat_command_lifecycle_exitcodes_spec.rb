# frozen_string_literal: true

require "json"
require "stringio"

# CLI lifecycle / headless-output correctness fixes:
#   ONESHOT-ACTIVE — a one-shot ends its session (status=ended), not active.
#   STRUCT-F1      — --max-turns exhaustion ⇒ is_error + non-zero exit (text/json).
#   STRUCT-F2      — a missing-key preflight emits a JSON error envelope on stdout
#                    under json/stream-json (not zero bytes).
#   F1-subagents   — a subagent-blocked headless run propagates exit 2 + stderr.
#
# Driven through REAL one-shot runs (FakeLLM + real DB), the same harness the
# #312 json spec uses, so the exit-code/envelope contract is exercised end-to-end.
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

  def last_json(stdout)
    JSON.parse(stdout.each_line.map(&:strip).reject(&:empty?).last)
  end

  # ONESHOT-ACTIVE — a non-interactive one-shot used to exit without firing the
  # teardown, leaving the session status=active forever (confusing auto-resume /
  # sessions list). It must now finalize the session to status=ended.
  describe "ending the one-shot session (ONESHOT-ACTIVE)" do
    it "marks the session ended after a text one-shot (status=ended)" do
      fake_llm.enqueue_text("done")

      stdout, _stderr, status = run_oneshot("query" => "hi")

      expect(stdout).to include("done")
      expect(status).to eq(0)
      rows = db.db[:sessions].all
      expect(rows).not_to be_empty
      expect(rows.map { |r| r[:status] }.uniq).to eq(["ended"])
    end

    it "marks the session ended after a json one-shot" do
      fake_llm.enqueue_text("done")

      _stdout, _stderr, status = run_oneshot("query" => "hi", "output_format" => "json")

      expect(status).to eq(0)
      expect(db.db[:sessions].all.map { |r| r[:status] }.uniq).to eq(["ended"])
    end
  end

  # STRUCT-F1 — a budget-truncated run (loop hit --max-turns → forced summary,
  # stop_reason :max_iterations) used to report subtype:"success"/is_error:false/
  # exit 0. It must now be flagged is_error + exit non-zero, across text/json/
  # stream-json. We make the model loop tool calls so the budget exhausts: with
  # --max-turns 1 the loop runs ONE tool iteration then force-summarizes.
  describe "--max-turns exhaustion reports truncation (STRUCT-F1)" do
    before do
      # With --max-turns 1 the loop runs exactly ONE tool iteration, then the
      # budget is exhausted and the Loop issues ONE final tools-stripped call for
      # the forced "here's what I got to" summary. So: one tool call (consumed in
      # iteration 0) + one text response (the forced summary).
      fake_llm.enqueue_tool_call("read", { "file_path" => "README.md" })
      fake_llm.enqueue_text("here is what I got to before the budget ran out")
    end

    it "text mode: exits non-zero with a truncation notice on stderr" do
      stdout, stderr, status = run_oneshot("query" => "go", "max_turns" => 1.0)

      expect(stdout).to include("here is what I got to")
      expect(status).not_to eq(0)
      expect(stderr).to match(/turn budget exhausted|max-turns|truncated/i)
    end

    it "json mode: is_error true, error_max_turns subtype, exit non-zero" do
      stdout, _stderr, status = run_oneshot(
        "query" => "go", "max_turns" => 1.0, "output_format" => "json"
      )

      obj = last_json(stdout)
      expect(obj["type"]).to eq("result")
      expect(obj["is_error"]).to be(true)
      expect(obj["subtype"]).to eq("error_max_turns")
      expect(obj["exit_reason"]).to eq("error_max_turns")
      # The forced summary (partial answer) is still carried for the caller.
      expect(obj["result"]).to include("here is what I got to")
      expect(status).not_to eq(0)
    end

    it "stream-json mode: terminal result frame is the is_error truncation" do
      stdout, _stderr, status = run_oneshot(
        "query" => "go", "max_turns" => 1.0, "output_format" => "stream-json"
      )

      result = last_json(stdout)
      expect(result["type"]).to eq("result")
      expect(result["is_error"]).to be(true)
      expect(result["subtype"]).to eq("error_max_turns")
      expect(status).not_to eq(0)
    end

    it "a NON-exhausted run still reports success / exit 0" do
      # Re-seed: a clean text completion, no tool loop, generous budget.
      fresh = FakeLLMAdapter.new
      fresh.enqueue_text("all done normally")
      allow(Rubino::LLM::RubyLLMAdapter).to receive(:new).and_return(fresh)

      stdout, _stderr, status = run_oneshot("query" => "hi", "output_format" => "json")

      obj = last_json(stdout)
      expect(obj["is_error"]).to be(false)
      expect(obj["subtype"]).to eq("success")
      expect(status).to eq(0)
    end
  end

  # STRUCT-F2 — a missing credential on the DEFAULT path (no -m/--provider) used
  # to exit(1) with good stderr but ZERO bytes on stdout, breaking the #327
  # contract that every json/stream-json run yields a parseable result object on
  # stdout. The preflight must now be format-aware.
  describe "missing-key preflight is format-aware (STRUCT-F2)" do
    before do
      # Force the credential gate to fire (default path, no override).
      allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(false)
      allow(Rubino::LLM::CredentialCheck).to receive(:missing_key_message)
        .and_return("no API key configured — run `rubino setup`")
      # Non-interactive so the wizard isn't attempted.
      allow($stdin).to receive(:tty?).and_return(false)
    end

    it "json mode: emits a well-formed error envelope on stdout + exit 1" do
      stdout, stderr, status = run_oneshot("query" => "hi", "output_format" => "json")

      expect(status).to eq(1)
      lines = stdout.each_line.map(&:strip).reject(&:empty?)
      expect(lines).not_to be_empty # NOT zero bytes anymore
      obj = JSON.parse(lines.last)
      expect(obj["type"]).to eq("result")
      expect(obj["is_error"]).to be(true)
      expect(obj.dig("error", "message")).to include("no API key configured")
      # Human message still on stderr.
      expect(stderr).to include("no API key configured")
    end

    it "stream-json mode: emits a parseable error result line on stdout + exit 1" do
      stdout, _stderr, status = run_oneshot("query" => "hi", "output_format" => "stream-json")

      expect(status).to eq(1)
      obj = last_json(stdout)
      expect(obj["type"]).to eq("result")
      expect(obj["is_error"]).to be(true)
    end

    it "text mode: still stderr-only (no JSON on stdout) + exit 1" do
      stdout, stderr, status = run_oneshot("query" => "hi")

      expect(status).to eq(1)
      expect(stdout.strip).to be_empty
      expect(stderr).to include("no API key configured")
    end
  end
end
