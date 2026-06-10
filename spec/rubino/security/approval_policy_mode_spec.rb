# frozen_string_literal: true

# Yolo mode short-circuits ApprovalPolicy#decide to :allow for the
# mode-based and permissions:allow/ask logic — yolo means "I accept the
# risk, get out of my way." But yolo is NOT a floor: it sits ABOVE the
# deny-class checks. As of S2 (deny-before-allow ordering), the hardline
# floor and an EXPLICIT permissions:deny rule both run BEFORE the yolo
# allow-exit, so neither can be overridden by yolo — an operator who wrote
# `shell rm *: deny` meant it. The doom detector also keeps running so an
# autopilot stuck in a loop still gets stopped.
RSpec.describe Rubino::Security::ApprovalPolicy do
  before(:all) { Rubino.loader.eager_load }

  let(:risky_tool) do
    Class.new do
      def name = "shell"
      def risk_level = :high
      def risky? = true
    end.new
  end

  describe "Modes.yolo short-circuit" do
    subject(:policy) { described_class.new(config: config) }

    let(:config) do
      test_configuration(
        "approvals" => { "mode" => "manual" },
        "permissions" => { "shell rm *" => "deny" }
      )
    end

    it "allows a risky shell call that would otherwise be :ask" do
      expect(policy.decide(risky_tool, arguments: { "command" => "make build" })).to eq(:ask)

      Rubino::Modes.set(:yolo)
      expect(policy.decide(risky_tool, arguments: { "command" => "make build" })).to eq(:allow)
    end

    it "STILL denies an explicit permissions:deny rule (deny-before-allow; S2)" do
      # yolo is not a floor: an operator's explicit `shell rm *: deny` is a
      # deny-class check that runs before the yolo allow-exit, so it wins.
      Rubino::Modes.set(:yolo)
      expect(policy.decide(risky_tool, arguments: { "command" => "rm -rf /tmp/x" })).to eq(:deny)
    end

    it "still trips the doom-loop detector even in yolo" do
      Rubino::Modes.set(:yolo)
      # Hammer the same call until the detector records it as a loop.
      30.times { policy.decide(risky_tool, arguments: { "command" => "ls" }) }
      # Once it trips, decide returns :deny — yolo doesn't override safety
      # against the agent stuck in its own loop.
      expect(policy.decide(risky_tool, arguments: { "command" => "ls" })).to eq(:deny)
    end
  end
end
