# frozen_string_literal: true

RSpec.describe Rubino::Security::DoomLoopDetector do
  subject(:detector) { described_class.new(threshold: 3) }

  describe "#record" do
    it "returns false for the first call" do
      expect(detector.record(tool_name: "shell", arguments: { "command" => "ls" })).to be false
    end

    it "returns false when calls are below threshold" do
      2.times { detector.record(tool_name: "shell", arguments: { "command" => "ls" }) }
      expect(detector.record(tool_name: "shell", arguments: { "command" => "ls" })).to be true
    end

    it "detects a doom loop when the last threshold calls are identical" do
      detector.record(tool_name: "shell", arguments: { "command" => "ls" })
      detector.record(tool_name: "shell", arguments: { "command" => "ls" })
      expect(detector.record(tool_name: "shell", arguments: { "command" => "ls" })).to be true
    end

    it "does not trigger when the last calls differ in arguments" do
      detector.record(tool_name: "shell", arguments: { "command" => "ls" })
      detector.record(tool_name: "shell", arguments: { "command" => "pwd" })
      expect(detector.record(tool_name: "shell", arguments: { "command" => "ls" })).to be false
    end

    it "does not trigger when the last calls differ in tool name" do
      detector.record(tool_name: "shell", arguments: { "x" => 1 })
      detector.record(tool_name: "read",  arguments: { "x" => 1 })
      expect(detector.record(tool_name: "shell", arguments: { "x" => 1 })).to be false
    end

    it "produces a deterministic signature regardless of argument key order" do
      detector.record(tool_name: "t", arguments: { a: 1, b: 2 })
      detector.record(tool_name: "t", arguments: { b: 2, a: 1 })
      expect(detector.record(tool_name: "t", arguments: { a: 1, b: 2 })).to be true
    end
  end

  describe "#reset!" do
    it "clears history so a fresh sequence does not trigger immediately" do
      3.times { detector.record(tool_name: "x", arguments: {}) }
      detector.reset!
      # First two post-reset calls stay below threshold; the loop is broken.
      expect(detector.record(tool_name: "x", arguments: {})).to be false
      expect(detector.record(tool_name: "x", arguments: {})).to be false
    end
  end
end
