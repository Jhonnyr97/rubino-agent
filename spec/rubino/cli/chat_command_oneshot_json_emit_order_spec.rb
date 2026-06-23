# frozen_string_literal: true

require "json"
require "stringio"

# WHATIF-headless RED-1: under --output-format json the post-turn job DRAIN used
# to run BEFORE emit_json, so the consumer got NOTHING on stdout until a (possibly
# foreign, 9-15+ min) backlog cleared — and a timeout kill yielded no JSON at all.
# The result envelope must reach stdout BEFORE any background-job draining. This
# spec pins the ordering: when #drain_post_turn_jobs! is invoked, the result JSON
# is already on stdout.
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
  end

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

  it "emits the result envelope to stdout BEFORE the post-turn drain runs (--json)" do
    fake_llm.enqueue_text("the final answer", input_tokens: 5, output_tokens: 3)

    stdout_at_drain = nil
    # Capture exactly what is on stdout the instant the drain runs. The drain
    # routes through Jobs::Queue#reap_inline_orphans, so intercept it there.
    allow_any_instance_of(Rubino::Jobs::Queue).to receive(:reap_inline_orphans) do # rubocop:disable RSpec/AnyInstance -- the command instantiates the Queue internally; intercepting the reaper is the cleanest drain-time hook
      stdout_at_drain = $stdout.is_a?(StringIO) ? $stdout.string.dup : ""
    end

    stdout, = run_oneshot("query" => "hello", "output_format" => "json")

    # The drain ran...
    expect(stdout_at_drain).not_to be_nil
    # ...and by the time it did, the full result object was already flushed.
    obj = JSON.parse(stdout_at_drain.each_line.map(&:strip).reject(&:empty?).last)
    expect(obj["type"]).to eq("result")
    expect(obj["result"]).to eq("the final answer")

    # And the final stdout is still the single well-formed result object.
    lines = stdout.each_line.map(&:strip).reject(&:empty?)
    expect(JSON.parse(lines.last)["result"]).to eq("the final answer")
  end
end
