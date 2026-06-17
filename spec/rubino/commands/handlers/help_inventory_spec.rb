# frozen_string_literal: true

# /help inventory drift (copy-nit): the `/help` listing and the unknown-command
# "Available:" roster must NEVER diverge — every built-in slash command lives in
# exactly ONE source (BuiltIns::DESCRIPTIONS), and both surfaces read it. This
# guards against a future divergence (e.g. /compact /branch /probe /queued
# /clear once appeared in "Available:" but not in /help).
RSpec.describe Rubino::Commands::Handlers::Help do
  # A scripted UI that records every info line, so we can assert the rendered
  # /help text mentions each command name.
  let(:ui) do
    Class.new do
      attr_reader :lines

      def initialize = @lines = []
      def info(msg = "") = @lines << msg.to_s
      def blank_line     = @lines << ""
      def respond_to_missing?(_name, _priv = false) = true
      def method_missing(_name, *_args) = nil
    end.new
  end

  let(:loader) do
    Class.new do
      def all   = []
      def names = []
    end.new
  end

  let(:handler) { described_class.new(ui: ui, loader: loader) }

  it "draws both surfaces from the single BuiltIns source" do
    # The roster the unknown-command hint prints is exactly the BuiltIns names
    # (plus any custom commands — none here), so the two can't drift by source.
    expect(handler.available_commands).to eq(Rubino::Commands::BuiltIns::NAMES)
    expect(Rubino::Commands::BuiltIns::NAMES).to eq(Rubino::Commands::BuiltIns::DESCRIPTIONS.keys)
  end

  it "lists EVERY built-in command in /help (no roster-only commands)" do
    handler.show_help
    rendered = ui.lines.join("\n")

    # Commands that were specifically reported as roster-only must now appear in
    # the /help body, alongside every other built-in.
    %w[/compact /branch /probe /queued /clear].each do |cmd|
      expect(rendered).to include(cmd), "expected /help to list #{cmd}"
    end

    Rubino::Commands::BuiltIns::NAMES.each do |cmd|
      expect(rendered).to include(cmd), "expected /help to list #{cmd}"
    end
  end
end
