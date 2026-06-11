# frozen_string_literal: true

# #154 — /quit (and Ctrl+D) with live background subagents used to exit
# silently, killing in-flight delegated work without a word. The exit gate now
# lists the live children and asks for confirmation (default No) on an
# interactive terminal; off a terminal the listed warning is the clear kill
# notice and the exit proceeds (never a hang).
RSpec.describe Rubino::CLI::ChatCommand do
  subject(:command) { described_class.new({}) }

  let(:registry) { Rubino::Tools::BackgroundTasks.instance }

  # A Null UI that records the warning/info lines and can play an interactive
  # terminal answering the confirm prompt.
  def recording_ui(interactive: false, answer: nil)
    Class.new(Rubino::UI::Null) do
      define_method(:interactive_terminal?) { interactive }
      define_method(:ask) { |_prompt| answer }
    end.new
  end

  describe "#confirm_quit?" do
    it "passes straight through when nothing is running" do
      ui = recording_ui
      expect(command.send(:confirm_quit?, ui)).to be(true)
      expect(ui.messages).to be_empty
    end

    it "lists the live children and stays on 'n' (default No)" do
      registry.reserve(subagent: "general", prompt: "long job")
      ui = recording_ui(interactive: true, answer: "n")

      expect(command.send(:confirm_quit?, ui)).to be(false)
      text = ui.messages.map { |m| m[:message].to_s }.join("\n")
      expect(text).to include("1 background subagent still running")
      expect(text).to include("partial side effects may remain")
      expect(text).to include("general")
    end

    it "treats an empty answer as No (y/N default)" do
      registry.reserve(subagent: "general", prompt: "long job")
      ui = recording_ui(interactive: true, answer: nil)
      expect(command.send(:confirm_quit?, ui)).to be(false)
    end

    it "quits on an explicit yes" do
      registry.reserve(subagent: "general", prompt: "long job")
      ui = recording_ui(interactive: true, answer: "y")
      expect(command.send(:confirm_quit?, ui)).to be(true)
    end

    it "pluralizes and counts multiple live children" do
      registry.reserve(subagent: "general", prompt: "a")
      registry.reserve(subagent: "explore", prompt: "b")
      ui = recording_ui(interactive: true, answer: "n")

      command.send(:confirm_quit?, ui)
      text = ui.messages.map { |m| m[:message].to_s }.join("\n")
      expect(text).to include("2 background subagents still running")
    end

    it "off a terminal prints the kill notice and proceeds (no hang)" do
      registry.reserve(subagent: "general", prompt: "long job")
      ui = recording_ui(interactive: false)

      expect(command.send(:confirm_quit?, ui)).to be(true)
      text = ui.messages.map { |m| m[:message].to_s }.join("\n")
      expect(text).to include("still running — quitting stops")
    end
  end
end
