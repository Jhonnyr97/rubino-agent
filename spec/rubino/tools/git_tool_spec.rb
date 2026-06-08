# frozen_string_literal: true

RSpec.describe Rubino::Tools::GitTool do
  subject(:tool) { described_class.new }

  it "has name 'git'" do
    expect(tool.name).to eq("git")
  end

  it "has :low risk level" do
    expect(tool.risk_level).to eq(:low)
  end

  it "has a non-empty description" do
    expect(tool.description).not_to be_empty
  end

  describe "#call — valid commands" do
    # We stub the shell execution so tests don't require a real git repo
    before do
      allow(tool).to receive(:`).and_return("mocked git output")
    end

    %w[status diff log branch show].each do |cmd|
      it "accepts the '#{cmd}' command" do
        result = tool.call("command" => cmd)
        expect(result).to be_a(String)
      end
    end
  end

  describe "#call — unknown command" do
    it "returns an error message for unknown git commands" do
      result = tool.call("command" => "push")
      expect(result).to include("Unknown git command")
    end
  end

  describe "#call — real git status (if in a git repo)" do
    it "does not raise an exception" do
      expect { tool.call("command" => "status") }.not_to raise_error
    end

    it "returns a non-nil string" do
      result = tool.call("command" => "status")
      expect(result).to be_a(String)
    end
  end
end
