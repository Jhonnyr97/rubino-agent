# frozen_string_literal: true

# #378 (residual of #361b) — the one-shot interrupt LABEL must be truthful. A
# bare Interrupt/SIGINT (the user pressing Ctrl-C) is a USER interrupt, NOT an
# external signal; only a SIGTERM/SIGHUP teardown (surfaced as a cooperative
# Rubino::Interrupted with reason :external) is "by external signal". The old
# label check defaulted any non-Rubino::Interrupted (i.e. a bare Interrupt) to
# external, so a plain Ctrl-C was mislabeled "interrupted by external signal".
RSpec.describe Rubino::CLI::ChatCommand do
  let(:db)      { test_database }
  let(:null_ui) { Rubino::UI::Null.new }

  def run_interrupted(error, json: false)
    runner = instance_double(Rubino::Agent::Runner)
    allow(Rubino::Agent::Runner).to receive(:new).and_return(runner)
    allow(runner).to receive(:cancel!)
    allow(runner).to receive(:run!).and_raise(error)
    allow(runner).to receive(:session).and_return({ id: "s1", model: "fake-model" })

    opts = { "query" => "hi" }
    opts["json"] = true if json
    status = nil
    captured = capture_stderr do
      described_class.new(opts).execute
    rescue SystemExit => e
      status = e.status
    end
    [captured, status]
  end

  # Capture stderr around a block (the label is warned to stderr in both modes).
  def capture_stderr
    orig = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = orig
  end

  before do
    allow(Rubino).to receive(:database).and_return(db)
    allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(true)
    Rubino.ui = null_ui
  end

  describe "text mode" do
    it "labels a bare Interrupt (Ctrl-C) as a USER interrupt, not external" do
      err, status = run_interrupted(Interrupt)
      expect(err).to match(/rubino: interrupted$/)
      expect(err).not_to include("external")
      expect(status).to eq(130)
    end

    it "labels a cooperative user Rubino::Interrupted as a USER interrupt" do
      err, status = run_interrupted(Rubino::Interrupted.new(reason: :user))
      expect(err).to match(/rubino: interrupted$/)
      expect(err).not_to include("external")
      expect(status).to eq(130)
    end

    it "labels an EXTERNAL-reason Rubino::Interrupted as external" do
      err, status = run_interrupted(Rubino::Interrupted.new(reason: :external))
      expect(err).to include("interrupted by external signal")
      expect(status).to eq(130)
    end
  end

  describe "--json mode" do
    it "labels a bare Interrupt (Ctrl-C) as a USER interrupt, not external" do
      err, status = run_interrupted(Interrupt, json: true)
      expect(err).to include("rubino: interrupted by user")
      expect(err).not_to include("external")
      expect(status).to eq(130)
    end

    it "labels an EXTERNAL-reason Rubino::Interrupted as external" do
      err, status = run_interrupted(Rubino::Interrupted.new(reason: :external), json: true)
      expect(err).to include("interrupted by external signal")
      expect(status).to eq(130)
    end
  end
end
