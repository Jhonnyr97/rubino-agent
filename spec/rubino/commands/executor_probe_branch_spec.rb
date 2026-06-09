# frozen_string_literal: true

# Dispatch specs for the two new principal-chat slash commands the Executor
# registers: /probe (the discoverable alias for the `? ` prefix) and /branch
# (fork-and-switch). The Executor itself has no LLM/runner seam, so it only
# returns the SIGNAL the REPL acts on; the actual inference/fork is verified in
# the ChatCommand spec.
RSpec.describe "Rubino::Commands::Executor probe & branch" do
  subject(:exec) { Rubino::Commands::Executor.new(loader: loader, ui: ui) }

  let(:db)     { test_database }
  let(:ui)     { Rubino::UI::Null.new }
  let(:loader) { Rubino::Commands::Loader.new(config: test_configuration) }

  before do
    allow(Rubino).to receive(:database).and_return(db)
    allow(Rubino).to receive(:configuration).and_return(test_configuration)
  end

  describe "/probe" do
    it "returns a {probe:} signal carrying the question text" do
      expect(exec.try_execute("/probe is this lib MIT or GPL?"))
        .to eq(probe: "is this lib MIT or GPL?")
    end

    it "bare /probe only teaches the `? ` prefix (no inference signalled)" do
      result = exec.try_execute("/probe")
      expect(result).to eq(:handled)
      tip = ui.messages.map { |m| m[:message].to_s }.join("\n")
      expect(tip).to include("? ")
    end
  end

  describe "/branch" do
    it "returns a {branch:, title:} signal with the optional name" do
      expect(exec.try_execute("/branch licensing-audit"))
        .to eq(branch: true, title: "licensing-audit")
    end

    it "leaves the title nil when /branch is bare" do
      expect(exec.try_execute("/branch")).to eq(branch: true, title: nil)
    end
  end

  it "registers /probe and /branch as discoverable built-ins" do
    expect(Rubino::Commands::BuiltIns::NAMES).to include("/probe", "/branch")
  end
end
