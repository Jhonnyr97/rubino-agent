# frozen_string_literal: true

RSpec.describe Rubino::Security::PatternMatcher do
  describe "#match — deny always wins (permissions invariant)" do
    # REGRESSION (H2): a longer, more-specific :allow that overlaps a shorter
    # :deny used to win because #match returned the first hit on the purely
    # length-sorted rule list. The documented invariant is "deny always wins",
    # so a shorter overlapping deny must beat a longer allow.
    it "a SHORTER deny beats a LONGER overlapping allow" do
      matcher = described_class.new(
        rules: {
          # The deny is shorter (and, with the wildcard -10 penalty, ranks LOWER
          # in the specificity sort) than the exact allow it overlaps. Pre-fix,
          # #match returned the first length-sorted hit (the allow) and the deny
          # was never seen — exactly the reproduced "git push --force-with-lease"
          # bypass.
          "shell git push*" => "deny",
          "shell git push --force-with-lease origin main" => "allow"
        }
      )
      expect(
        matcher.match("shell", "git push --force-with-lease origin main")
      ).to eq(:deny)
    end

    it "deny wins even when the allow is the only length-sorted first hit" do
      matcher = described_class.new(
        rules: {
          "shell *" => "deny",
          "shell rm -rf /tmp/cache" => "allow"
        }
      )
      expect(matcher.match("shell", "rm -rf /tmp/cache")).to eq(:deny)
    end

    it "deny wins over an overlapping ask too" do
      matcher = described_class.new(
        rules: {
          "shell git *" => "deny",
          "shell git push --tags" => "ask"
        }
      )
      expect(matcher.match("shell", "git push --tags")).to eq(:deny)
    end
  end

  describe "#match — longest-match preserved WITHIN the allow/ask class" do
    it "the most-specific allow wins when no deny matches" do
      matcher = described_class.new(
        rules: {
          "shell *" => "ask",
          "shell git status" => "allow"
        }
      )
      expect(matcher.match("shell", "git status")).to eq(:allow)
      # A command only the broad rule covers still gets :ask.
      expect(matcher.match("shell", "git push")).to eq(:ask)
    end

    it "returns nil when nothing matches" do
      matcher = described_class.new(rules: { "git *" => "allow" })
      expect(matcher.match("shell", "ls -la")).to be_nil
    end
  end

  describe "#match — existing allow/deny semantics stay green" do
    it "an explicit deny on a non-overlapping command does not leak" do
      matcher = described_class.new(
        rules: { "shell rm *" => "deny", "shell *" => "allow" }
      )
      expect(matcher.match("shell", "rm -rf x")).to eq(:deny)
      expect(matcher.match("shell", "ls")).to eq(:allow)
    end
  end
end
