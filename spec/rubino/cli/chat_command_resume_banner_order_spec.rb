# frozen_string_literal: true

require "stringio"

# A bad `--resume <id>` used to print the rubino/workspace/branch/model boot
# banner on stdout and ONLY THEN the "Session not found" error on stderr,
# making a failed resume look like a session was starting. The id is now
# validated BEFORE the banner, so a bad id errors cleanly (stderr + exit 1)
# with NO banner on stdout. The happy path (valid id) is unchanged.
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
  end

  # Drives the chat entry with stdin = /dev/null (empty) so a nil query routes
  # to the interactive path — the exact `rubino chat --resume <id> </dev/null`
  # the QA used. Captures stdout + stderr + the SystemExit status.
  def run_chat(opts)
    out = StringIO.new
    err = StringIO.new
    status = 0
    orig_out = $stdout
    orig_err = $stderr
    orig_in  = $stdin
    $stdout = out
    $stderr = err
    $stdin  = StringIO.new("")
    begin
      described_class.new(opts).execute
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = orig_out
      $stderr = orig_err
      $stdin  = orig_in
    end
    [out.string, err.string, status]
  end

  describe "--resume of an unknown id" do
    it "errors on stderr with exit 1 and NO boot banner on stdout" do
      stdout, stderr, status = run_chat(resume: "nonexistent-id-123")

      expect(status).to eq(1)
      expect(stderr).to include("Session not found: nonexistent-id-123")
      # The misleading banner (rubino / workspace / branch / model) must NOT
      # have been emitted before the error.
      expect(stdout).not_to include("workspace")
      expect(stdout).not_to match(/^rubino$/)
    end
  end
end
