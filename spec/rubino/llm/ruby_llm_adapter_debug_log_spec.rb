# frozen_string_literal: true

require "tmpdir"

# Issue #27: the RUBYLLM_DEBUG log path must follow the resolved home
# (RUBINO_HOME -> else ~/.rubino) instead of a hardcoded ~/.rubino/logs, so an
# isolated/custom home is not polluted with a log written into the default home.
RSpec.describe "Rubino::LLM::RubyLLMAdapter#debug_log_path RUBINO_HOME resolution" do
  subject(:adapter) { Rubino::LLM::RubyLLMAdapter.allocate }

  let(:custom_home) { Dir.mktmpdir("rubino-home") }

  around do |example|
    prev = ENV.fetch("RUBINO_HOME", nil)
    ENV["RUBINO_HOME"] = custom_home
    example.run
  ensure
    ENV["RUBINO_HOME"] = prev
    FileUtils.rm_rf(custom_home)
  end

  it "derives the debug-log path from the resolved RUBINO_HOME" do
    expect(adapter.send(:debug_log_path))
      .to eq(File.join(custom_home, "logs", "ruby_llm.log"))
  end

  it "does not write the debug log into the default ~/.rubino" do
    expect(adapter.send(:debug_log_path)).not_to include(File.expand_path("~/.rubino"))
  end
end
