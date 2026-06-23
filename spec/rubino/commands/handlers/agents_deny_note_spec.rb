# frozen_string_literal: true

# #Y1B — "Deny & tell the agent why" hands the child an ADVISORY steer note so
# it learns WHY its action was refused. The note must carry the shared
# BackgroundTasks::DENY_NOTE_PREFIX so the completion path can tell it apart
# from a genuine `/agents <id> steer` note and NOT raise the scary
# "steer note not delivered (task completed first)" warning when the child
# finished before reading it (the denial already applied — the note is moot).
RSpec.describe Rubino::Commands::Handlers::Agents, "#deny_with_explanation (#Y1B)" do
  let(:reason) { "that file is out of scope" }
  let(:ui) do
    Class.new do
      def ask(_prompt) = "that file is out of scope"
      def respond_to_missing?(_name, _priv = false) = true
      def method_missing(_name, *_args) = nil
    end.new
  end

  let(:handler) { described_class.new(ui: ui) }
  let(:entry)   { Struct.new(:id).new("sa_deadbeef") }

  it "hands the reason to the child as a DENY_NOTE_PREFIX-tagged steer note" do
    expect(Rubino::Tools::BackgroundTasks.instance)
      .to receive(:steer)
      .with("sa_deadbeef", "#{Rubino::Tools::BackgroundTasks::DENY_NOTE_PREFIX}#{reason}")

    expect(handler.send(:deny_with_explanation, entry)).to be(false)
  end

  it "queues nothing when the reason is blank (still denies)" do
    allow(ui).to receive(:ask).and_return("   ")
    expect(Rubino::Tools::BackgroundTasks.instance).not_to receive(:steer)

    expect(handler.send(:deny_with_explanation, entry)).to be(false)
  end
end
