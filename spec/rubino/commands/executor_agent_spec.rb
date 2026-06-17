# frozen_string_literal: true

# Covers the primary-agent switching slash commands in Commands::Executor
# (#320), distinct from `/agents` (the background-task drill-in). `/agent` lists
# and pins; a dynamic `/<agent-name>` either pins a primary (bare) or routes one
# turn to any agent (`/<name> <message>`).
RSpec.describe Rubino::Commands::Executor do
  subject(:exec) { described_class.new(loader: loader, ui: ui) }

  let(:ui)     { Rubino::UI::Null.new }
  let(:loader) { Rubino::Commands::Loader.new(config: test_configuration) }

  before { Rubino::ActiveAgent.reset! }
  after  { Rubino::ActiveAgent.reset! }

  describe "/agent" do
    it "lists the primary agents (no switch, no turn)" do
      result = exec.try_execute("/agent")
      expect(result).to eq(:handled)
      listing = ui.messages.map { |m| m[:message] }.join("\n")
      expect(listing).to include("/build").and include("/plan")
    end

    it "pins a primary via /agent <name> with a {select_agent:} signal" do
      result = exec.try_execute("/agent plan")
      expect(result).to eq({ select_agent: "plan" })
    end

    it "rejects /agent <subagent> (explore is not switchable)" do
      result = exec.try_execute("/agent explore")
      expect(result).to eq(:handled)
      info = ui.messages.map { |m| m[:message] }.join("\n")
      expect(info).to include("subagent")
    end
  end

  describe "/<agent-name>" do
    it "routes a single turn to a subagent via /<name> <message>" do
      result = exec.try_execute("/explore where is the parser")
      expect(result).to eq({ prompt: "where is the parser", agent: "explore" })
    end

    it "routes a single turn to a primary via /<name> <message>" do
      result = exec.try_execute("/plan outline the refactor")
      expect(result).to eq({ prompt: "outline the refactor", agent: "plan" })
    end

    it "pins a primary when /<name> is bare" do
      result = exec.try_execute("/plan")
      expect(result).to eq({ select_agent: "plan" })
    end

    it "teaches usage for a bare subagent name (no turn)" do
      result = exec.try_execute("/general")
      expect(result).to eq(:handled)
      info = ui.messages.map { |m| m[:message] }.join("\n")
      expect(info).to include("/general <message>")
    end

    it "does not shadow an unrelated unknown command" do
      result = exec.try_execute("/totallyunknown")
      # Falls through to the unknown-command path (handled, with an error).
      expect(result).to eq(:handled)
      expect(ui.messages.any? { |m| m[:level] == :error }).to be(true)
    end
  end
end
