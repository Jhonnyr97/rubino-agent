# frozen_string_literal: true

# item 5 — dangling subagent-id hint. Subagent ids (sa_*) live ONLY in the
# current process (the BackgroundTasks registry is in-memory, never persisted),
# so a prior session's id is genuinely gone after a REPL restart. Every
# not-found path (/agents <id>, /reply <id>, /stop <id>, steer, probe) used to
# return a bare "no such id"; these specs pin that each now appends the
# RESET_HINT so the user knows the id reset on restart instead of hunting for a
# typo.
RSpec.describe Rubino::Commands::Handlers::Agents do
  let(:ui) do
    Class.new do
      attr_reader :lines

      def initialize = @lines = []
      def info(msg = "")    = @lines << msg.to_s
      def success(msg = "") = @lines << msg.to_s
      def error(msg = "")   = @lines << msg.to_s
      def separator         = nil
      def ask(_prompt)      = nil
      def respond_to_missing?(_name, _priv = false) = true
      def method_missing(_name, *_args) = nil
    end.new
  end

  let(:handler) { described_class.new(ui: ui) }

  before { Rubino::Tools::BackgroundTasks.reset! }
  after  { Rubino::Tools::BackgroundTasks.reset! }

  def last_error = ui.lines.last.to_s

  it "exposes the reset hint as a constant" do
    expect(described_class::RESET_HINT).to match(/subagents reset when rubino restarts/i)
  end

  it "hints on /agents <unknown-id>" do
    handler.handle_agents("sa_gone")
    expect(last_error).to include(described_class::RESET_HINT)
    expect(last_error).to include("sa_gone")
  end

  it "hints on /stop <unknown-id> (/agents <id> --stop)" do
    handler.handle_agents("sa_gone --stop")
    expect(last_error).to include(described_class::RESET_HINT)
  end

  it "hints on the /stop alias for an unknown id" do
    handler.handle_stop_alias("sa_gone")
    expect(last_error).to include(described_class::RESET_HINT)
  end

  it "hints on /reply <unknown-id>" do
    handler.handle_reply("sa_gone an answer")
    expect(last_error).to include(described_class::RESET_HINT)
  end

  it "hints on steer for an unknown id" do
    handler.handle_agents(%(sa_gone steer "be terse"))
    expect(last_error).to include(described_class::RESET_HINT)
  end

  it "hints on probe for an unknown id" do
    handler.handle_agents(%(sa_gone probe "what now"))
    expect(last_error).to include(described_class::RESET_HINT)
  end
end
