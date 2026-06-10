# frozen_string_literal: true

# Covers the `/mode` slash command path in Commands::Executor. The Executor
# delegates to Rubino::Modes.set so this spec also pins the wiring:
# typing `/mode plan` at the prompt MUST flip the global mode AND emit a
# mode_changed UI event (so the API adapter can forward it to web clients).
RSpec.describe Rubino::Commands::Executor do
  subject(:exec) { described_class.new(loader: loader, ui: ui) }

  let(:ui)       { Rubino::UI::Null.new }
  let(:loader)   { Rubino::Commands::Loader.new(config: test_configuration) }

  describe "/mode" do
    it "switches mode and emits mode_changed with the previous value" do
      expect(Rubino::Modes.current).to eq(:default)

      result = exec.try_execute("/mode plan")

      expect(result).to eq(:handled)
      expect(Rubino::Modes.current).to eq(:plan)
      event = ui.messages.find { |m| m[:level] == :mode_changed }
      expect(event).to include(level: :mode_changed, message: :plan, previous: :default)
    end

    it "switches to yolo" do
      exec.try_execute("/mode yolo")
      expect(Rubino::Modes.current).to eq(:yolo)
    end

    # #152: an explicit /mode yolo stays direct (no confirm step — it's a
    # deliberate command), but when background children are LIVE their gates
    # drop the same instant, so one warning line says so.
    it "warns about live background children when switching to yolo" do
      Rubino::Tools::BackgroundTasks.instance.reserve(subagent: "explore", prompt: "x")
      exec.try_execute("/mode yolo")
      expect(Rubino::Modes.current).to eq(:yolo)
      warning = ui.messages.find { |m| m[:level] == :warning }
      expect(warning[:message]).to include("1 running background subagent(s)")
      expect(warning[:message]).to include("unprompted")
    ensure
      Rubino::Tools::BackgroundTasks.reset!
    end

    it "stays quiet about children when none are live, and when leaving yolo" do
      exec.try_execute("/mode yolo")
      exec.try_execute("/mode default")
      expect(ui.messages.none? { |m| m[:level] == :warning }).to be(true)
    end

    it "accepts trailing whitespace and capitalisation" do
      exec.try_execute("/mode   PLAN  ")
      expect(Rubino::Modes.current).to eq(:plan)
    end

    it "reports a typo as an error and keeps the previous mode untouched" do
      Rubino::Modes.set(:plan)
      exec.try_execute("/mode warp")
      expect(Rubino::Modes.current).to eq(:plan)
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("unknown mode")
    end

    it "with no argument lists all modes and marks the current one" do
      exec.try_execute("/mode")
      lines = ui.messages.select { |m| m[:level] == :info }.map { |m| m[:message] }
      expect(lines).to include(include("Current mode: default"))
      expect(lines).to include(include("▸ /mode default"))
      expect(lines).to include(include("  /mode plan"))
      expect(lines).to include(include("  /mode yolo"))
    end

    it "treats `/mode list` like a bare `/mode`" do
      exec.try_execute("/mode list")
      expect(ui.messages.find { |m| m[:level] == :info && m[:message].to_s.match(/Current mode/) }).not_to be_nil
      expect(Rubino::Modes.current).to eq(:default)
    end
  end

  describe "BuiltIns NAMES exposes /mode for tab-completion" do
    it "includes /mode in the completion set" do
      expect(Rubino::Commands::BuiltIns::NAMES).to include("/mode")
    end
  end

  # F14: /help omitted the `@` workspace file-picker (a discoverable composer
  # feature that works) and the Tab-completion behaviour.
  describe "/help documents the @ file-picker (F14)" do
    it "lists the @ file-picker and Tab completion alongside the slash commands" do
      exec.try_execute("/help")
      lines = ui.messages.select { |m| m[:level] == :info }.map { |m| m[:message].to_s }

      expect(lines).to include(include("@<path>"))
      expect(lines).to include(match(/\bTab\b/))
      # Still lists the built-in slash commands.
      expect(lines).to include(include("/help"))
    end
  end
end
