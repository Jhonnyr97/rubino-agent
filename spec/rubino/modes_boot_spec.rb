# frozen_string_literal: true

# Boot-mode pinning (#3). A fresh process forgets the active mode unless an
# external supervisor pins it via RUBINO_BOOT_MODE. These examples simulate a
# restart by clearing the memoised process state (which is all a real restart
# does) and asserting the boot path picks the mode back up from the env.
RSpec.describe Rubino::Modes do
  # `current` memoises into @current; nilling it is exactly what a fresh
  # process looks like, so the next `.current` re-runs the boot path.
  def simulate_restart!
    described_class.instance_variable_set(:@current, nil)
  end

  around do |example|
    previous = ENV.fetch("RUBINO_BOOT_MODE", nil)
    example.run
    ENV["RUBINO_BOOT_MODE"] = previous
    described_class.reset!
  end

  context "without RUBINO_BOOT_MODE (interactive default)" do
    it "boots in :default and resets to :default across a restart" do
      ENV.delete("RUBINO_BOOT_MODE")

      simulate_restart!
      expect(described_class.current).to eq(:default)
    end
  end

  context "with RUBINO_BOOT_MODE set (supervisor pins the mode)" do
    it "restores the pinned mode after a restart instead of silently dropping to :default" do
      # Caller sets yolo during the session...
      described_class.set(:yolo)
      expect(described_class.current).to eq(:yolo)

      # ...and the supervisor re-applies config with the same mode pinned in
      # the process environment, then bounces the process.
      ENV["RUBINO_BOOT_MODE"] = "yolo"
      simulate_restart!

      # Before the fix this came back :default; now the mode survives.
      expect(described_class.current).to eq(:yolo)
    end

    it "normalises case and surrounding whitespace" do
      ENV["RUBINO_BOOT_MODE"] = "  PLAN  "
      simulate_restart!
      expect(described_class.current).to eq(:plan)
    end

    it "ignores an unknown value rather than crashing boot" do
      ENV["RUBINO_BOOT_MODE"] = "warp"
      simulate_restart!
      expect(described_class.current).to eq(:default)
    end

    it "treats a blank value as unset" do
      ENV["RUBINO_BOOT_MODE"] = "   "
      simulate_restart!
      expect(described_class.current).to eq(:default)
    end
  end
end
