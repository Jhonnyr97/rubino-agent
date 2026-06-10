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

    # #20: a `disabled` row with no pointer is a dead end — a one-line footer
    # names the exact config command that re-enables the group.
    it "prints an enable-hint footer when a tool group is disabled" do
      Rubino::Tools::Registry.reset!
      allow(Rubino.configuration).to receive(:dig).and_call_original
      allow(Rubino.configuration).to receive(:dig).with("tools", "web").and_return(false)

      described_class.new.execute

      infos = ui.messages.select { |m| m[:level] == :info }.map { |m| m[:message].to_s }
      expect(infos.join("\n")).to include("rubino config set tools.<name> true")
      expect(infos.join("\n")).to include("tools.web")
    end

    it "prints no enable-hint when every tool group is enabled" do
      Rubino::Tools::Registry.reset!
      # web is disabled by default config; flip it on so every group reads enabled.
      allow(Rubino.configuration).to receive(:dig).and_call_original
      allow(Rubino.configuration).to receive(:dig).with("tools", "web").and_return(true)

      described_class.new.execute

      infos = ui.messages.select { |m| m[:level] == :info }.map { |m| m[:message].to_s }
      expect(infos.join("\n")).not_to include("rubino config set")
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
