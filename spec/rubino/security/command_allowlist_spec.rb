# frozen_string_literal: true

RSpec.describe Rubino::Security::CommandAllowlist do
  def allowlist(entries)
    config = test_configuration("security" => { "command_allowlist" => entries })
    described_class.new(config: config)
  end

  describe "#allowed?" do
    it "matches a command that prefix-matches a listed entry" do
      expect(allowlist(["git status"]).allowed?("git status -s")).to be(true)
    end

    it "rejects a command that does not match any entry" do
      expect(allowlist(["git status"]).allowed?("rm -rf /")).to be(false)
    end

    it "ignores surrounding whitespace on both sides" do
      expect(allowlist(["  ls "]).allowed?("  ls -la")).to be(true)
    end

    # Regression: an empty allowlist used to return true (match everything),
    # silently auto-approving every command. Pre-approval is opt-in.
    it "matches NOTHING when the allowlist is empty" do
      expect(allowlist([]).allowed?("git status")).to be(false)
    end
  end
end
