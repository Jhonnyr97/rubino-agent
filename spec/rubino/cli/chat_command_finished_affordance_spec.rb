# frozen_string_literal: true

# Item 5: the idle non-blocking completion affordance.
#
# When a BACKGROUND subagent finishes while the parent sits at the idle prompt,
# the parent should surface a one-line `✓ sa_… finished — /agents <id> for the
# result` note and stay free — no blocking, no polling. ChatCommand drives this
# from its idle poll loop via #surface_finished_subagents, announcing each
# finished child ONCE (so the ~50ms poll never repeats the line) and only for a
# CLEAN completion (a :failed / :stopped child already gets its own worker
# notice, so re-announcing would double-report).
RSpec.describe Rubino::CLI::ChatCommand do
  subject(:cmd) { described_class.new(provider: "fake", model: "fake/test") }

  # A UI that RECORDS #note (the affordance funnel) so we can assert on it.
  let(:ui) do
    Class.new do
      attr_reader :notes

      def initialize = @notes = []
      def note(text) = @notes << text.to_s
      def respond_to_missing?(_name, _priv = false) = true
      def method_missing(_name, *_args) = nil
    end.new
  end

  let(:registry) { Rubino::Tools::BackgroundTasks.instance }

  before do
    Rubino.ui = ui
    Rubino::Tools::BackgroundTasks.reset!
  end

  after do
    Rubino::Tools::BackgroundTasks.reset!
    Rubino.ui = nil
  end

  def finish(subagent: "explore", status: :completed)
    entry = registry.reserve(subagent: subagent, prompt: "do work")
    registry.complete(entry, status: status, result: "done", error: status == :failed ? "boom" : nil)
    entry
  end

  describe "#surface_finished_subagents" do
    it "announces a freshly-completed background subagent as a /agents one-liner" do
      entry = finish

      cmd.send(:surface_finished_subagents)

      line = ui.notes.last
      expect(line).to include("✓ #{entry.id}")
      expect(line).to include("(explore)")
      expect(line).to include("finished — /agents #{entry.id} for the result")
    end

    it "announces each finished child only ONCE across repeated idle ticks" do
      finish
      3.times { cmd.send(:surface_finished_subagents) }
      expect(ui.notes.size).to eq(1)
    end

    it "stays silent for a child that is still running (nothing to announce)" do
      registry.reserve(subagent: "explore", prompt: "still going")
      cmd.send(:surface_finished_subagents)
      expect(ui.notes).to be_empty
    end

    it "does NOT re-announce a :failed or :stopped child (it has its own notice)" do
      finish(status: :failed)
      finish(status: :stopped)
      cmd.send(:surface_finished_subagents)
      expect(ui.notes).to be_empty
    end

    it "never raises out of the idle loop on a UI hiccup" do
      finish
      allow(Rubino.ui).to receive(:note).and_raise(StandardError, "render glitch")
      expect { cmd.send(:surface_finished_subagents) }.not_to raise_error
    end
  end
end
