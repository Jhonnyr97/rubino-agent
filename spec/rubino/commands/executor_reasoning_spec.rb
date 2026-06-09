# frozen_string_literal: true

# Covers the `/reasoning` slash command in Commands::Executor. The command
# writes display.reasoning on the live configuration (so the LLM adapter gate
# and the CLI render path stay on one source of truth) and emits a
# reasoning_changed / reasoning_status UI event.
RSpec.describe Rubino::Commands::Executor do
  subject(:exec) { described_class.new(loader: loader, ui: ui) }

  let(:ui)       { Rubino::UI::Null.new }
  let(:loader)   { Rubino::Commands::Loader.new(config: test_configuration) }

  describe "/reasoning" do
    it "switches the render mode on config and emits reasoning_changed" do
      result = exec.try_execute("/reasoning full")

      expect(result).to eq(:handled)
      expect(Rubino.configuration.dig("display", "reasoning")).to eq("full")
      event = ui.messages.find { |m| m[:level] == :reasoning_changed }
      expect(event).to include(level: :reasoning_changed, message: :full, previous: :collapsed)
    end

    it "switches to hidden" do
      exec.try_execute("/reasoning hidden")
      expect(Rubino.configuration.dig("display", "reasoning")).to eq("hidden")
    end

    it "accepts trailing whitespace and capitalisation" do
      exec.try_execute("/reasoning   FULL  ")
      expect(Rubino.configuration.dig("display", "reasoning")).to eq("full")
    end

    it "reports an unknown value as an error and leaves the mode untouched" do
      exec.try_execute("/reasoning warp")
      expect(Rubino::Config::ReasoningPrefs.mode(Rubino.configuration)).to eq(:collapsed)
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("unknown reasoning mode")
    end

    it "with no argument shows the current mode" do
      exec.try_execute("/reasoning")
      event = ui.messages.find { |m| m[:level] == :reasoning_status }
      expect(event).to include(level: :reasoning_status, message: :collapsed)
    end
  end

  describe "/think" do
    it "switches the effort on config and emits think_changed" do
      result = exec.try_execute("/think high")

      expect(result).to eq(:handled)
      expect(Rubino.configuration.dig("thinking", "effort")).to eq("high")
      event = ui.messages.find { |m| m[:level] == :think_changed }
      expect(event).to include(level: :think_changed, message: :high, previous: :medium)
    end

    it "switches to off" do
      exec.try_execute("/think off")
      expect(Rubino.configuration.dig("thinking", "effort")).to eq("off")
    end

    it "reports an unknown value as an error" do
      exec.try_execute("/think extreme")
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("unknown effort")
    end

    it "with no argument shows the current effort" do
      exec.try_execute("/think")
      event = ui.messages.find { |m| m[:level] == :think_status }
      expect(event).to include(level: :think_status, message: :medium)
    end
  end

  describe "BuiltIns NAMES exposes the new commands for tab-completion" do
    it "includes /reasoning and /think in the completion set" do
      expect(Rubino::Commands::BuiltIns::NAMES).to include("/reasoning", "/think")
    end
  end
end
