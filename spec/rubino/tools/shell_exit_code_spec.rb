# frozen_string_literal: true

# Structured exit_code / timed_out / cancelled are surfaced as their own keys
# on the result hash so callers don't have to regex-grep `[Exit code: N]` out
# of free-form text to know whether a command succeeded.
RSpec.describe Rubino::Tools::ShellTool do
  subject(:tool) { described_class.new }

  describe "exit_code as a structured field" do
    it "is 0 for a clean exit" do
      out = tool.call("command" => "true")
      expect(out[:exit_code]).to eq(0)
      expect(out[:timed_out]).to be(false)
      expect(out[:cancelled]).to be(false)
      expect(out[:metrics]).to start_with("exit 0")
    end

    it "is the non-zero status for a failing command" do
      out = tool.call("command" => "exit 7")
      expect(out[:exit_code]).to eq(7)
      expect(out[:metrics]).to start_with("exit 7")
      expect(out[:output]).to include("[Exit code: 7]")
    end

    it "marks timed_out=true when the command exceeds its timeout" do
      out = tool.call("command" => "sleep 5", "timeout" => 1)
      expect(out[:timed_out]).to be(true)
      expect(out[:cancelled]).to be(false)
      expect(out[:metrics]).to start_with("timeout")
      expect(out[:output]).to include("timed out")
    end

    it "marks cancelled=true when cancel_token flips mid-run" do
      token = Class.new do
        def initialize; @polls = 0; end
        def cancelled?; @polls += 1; @polls > 3; end # flip after a few polls
      end.new
      tool.cancel_token = token

      out = tool.call("command" => "sleep 3", "timeout" => 10)
      expect(out[:cancelled]).to be(true)
      expect(out[:timed_out]).to be(false)
      expect(out[:metrics]).to start_with("cancelled")
      expect(out[:output]).to include("cancelled by user")
    end
  end
end
