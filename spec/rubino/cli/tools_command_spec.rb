# frozen_string_literal: true

RSpec.describe Rubino::CLI::ToolsCommand do
  let(:ui) { Rubino::UI::Null.new }

  before { Rubino.ui = ui }

  # F6: `rubino tools` printed an EMPTY table because the registry is
  # populated lazily when an agent runner boots, and the bare command never
  # boots one. It now registers the defaults (idempotently) so the table lists
  # the real, available tools.
  describe "#execute" do
    it "lists the registered default tools (non-empty) on a cold registry" do
      Rubino::Tools::Registry.reset!

      described_class.new.execute

      table = ui.messages.find { |m| m[:level] == :table }
      expect(table).not_to be_nil
      rows = table[:message][:rows]
      expect(rows).not_to be_empty
      tool_keys = rows.map(&:first)
      # Sample a few config-key groups that must appear once defaults register.
      expect(tool_keys).to include("shell", "edit", "grep", "web")
    end

    it "does not wipe an already-populated registry" do
      Rubino::Tools::Registry.reset!
      Rubino::Tools::Registry.register(Rubino::Tools::ShellTool.new)
      before = Rubino::Tools::Registry.all.size

      described_class.new.execute

      expect(Rubino::Tools::Registry.all.size).to eq(before)
    end
  end
end
