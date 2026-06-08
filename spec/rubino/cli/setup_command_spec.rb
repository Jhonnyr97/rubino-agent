# frozen_string_literal: true

require "tmpdir"

# #31: the final "Setup complete!" line must reflect reality. After a
# non-interactive run (no onboarding) with no usable credential configured,
# the wizard must NOT claim success; it must say a model still needs
# configuring. When a usable credential IS present, it reports success.
RSpec.describe Rubino::CLI::SetupCommand do
  let(:home) { Dir.mktmpdir("ra-setup") }

  # Spy UI: records each (level, message) so we can assert on the final line.
  let(:ui) do
    Class.new do
      attr_reader :messages
      def initialize = @messages = []
      def info(m)       = @messages << [:info, m]
      def success(m)    = @messages << [:success, m]
      def warning(m)    = @messages << [:warning, m]
      def status(m)     = @messages << [:status, m]
      def blank_line(*) = nil
      def error(m)      = @messages << [:error, m]
    end.new
  end

  around do |ex|
    prev = ENV["RUBINO_HOME"]
    ENV["RUBINO_HOME"] = home
    saved = ENV.to_hash.slice("MINIMAX_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY")
    %w[MINIMAX_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY].each { |k| ENV.delete(k) }
    ex.run
  ensure
    ENV["RUBINO_HOME"] = prev
    %w[MINIMAX_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(home)
  end

  before do
    allow(Rubino).to receive(:ui).and_return(ui)
    # Non-interactive: skip the onboarding prompt entirely.
    allow_any_instance_of(described_class).to receive(:interactive?).and_return(false)
  end

  def success_lines
    ui.messages.select { |lvl, _| lvl == :success }.map(&:last)
  end

  it "does NOT print a false 'Setup complete!' when no model is configured" do
    allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(false)

    described_class.new.execute

    expect(success_lines).not_to include(a_string_matching(/Setup complete/))
    expect(ui.messages).to include([:warning, a_string_matching(/no model is configured/i)])
  end

  it "prints 'Setup complete!' once a usable credential is configured" do
    allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(true)

    described_class.new.execute

    expect(success_lines).to include(a_string_matching(/Setup complete/))
  end
end
