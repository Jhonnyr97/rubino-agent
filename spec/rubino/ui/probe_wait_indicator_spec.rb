# frozen_string_literal: true

RSpec.describe Rubino::UI::ProbeWaitIndicator do
  subject(:host) { Class.new { include Rubino::UI::ProbeWaitIndicator }.new }

  # A UI double that records whether the thinking row was toggled.
  let(:ui) do
    Class.new do
      attr_reader :started, :finished

      def thinking_started   = @started = true
      def thinking_finished  = @finished = true
    end.new
  end

  describe "#probe_thinking_started" do
    it "starts the thinking row on a TTY when the UI supports it" do
      allow($stdout).to receive(:tty?).and_return(true)
      host.probe_thinking_started(ui)
      expect(ui.started).to be(true)
    end

    it "stays silent off a TTY" do
      allow($stdout).to receive(:tty?).and_return(false)
      host.probe_thinking_started(ui)
      expect(ui.started).to be_nil
    end

    it "stays silent when the UI does not respond to thinking_started" do
      allow($stdout).to receive(:tty?).and_return(true)
      expect { host.probe_thinking_started(Object.new) }.not_to raise_error
    end
  end

  describe "#probe_thinking_finished" do
    it "finishes the thinking row when the UI supports it (regardless of TTY)" do
      host.probe_thinking_finished(ui)
      expect(ui.finished).to be(true)
    end

    it "is a no-op when the UI does not respond to thinking_finished" do
      expect { host.probe_thinking_finished(Object.new) }.not_to raise_error
    end
  end
end
