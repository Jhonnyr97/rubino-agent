# frozen_string_literal: true

RSpec.describe Rubino::Run::SessionApprovalCache do
  subject(:cache) { described_class.new }

  describe "#remember + #allowed?" do
    it "stores session decisions" do
      cache.remember("sess-1", "shell:ls", "session")
      expect(cache.allowed?("sess-1", "shell:ls")).to be(true)
    end

    it "stores always decisions" do
      cache.remember("sess-1", "shell:ls", "always")
      expect(cache.allowed?("sess-1", "shell:ls")).to be(true)
    end

    it "does NOT store once decisions (caller must re-prompt next time)" do
      cache.remember("sess-1", "shell:ls", "once")
      expect(cache.allowed?("sess-1", "shell:ls")).to be(false)
    end

    it "does NOT store deny decisions" do
      cache.remember("sess-1", "shell:ls", "deny")
      expect(cache.allowed?("sess-1", "shell:ls")).to be(false)
    end

    it "isolates between sessions — sess-1's approval doesn't leak to sess-2" do
      cache.remember("sess-1", "shell:rm", "session")
      expect(cache.allowed?("sess-2", "shell:rm")).to be(false)
    end

    it "treats different scopes within the same session independently" do
      cache.remember("sess-1", "shell:ls",       "session")
      expect(cache.allowed?("sess-1", "shell:rm")).to be(false)
    end

    it "is a no-op when session_id is blank" do
      cache.remember(nil, "shell:ls", "session")
      expect(cache.allowed?(nil, "shell:ls")).to be(false)
    end

    it "is a no-op when scope is blank" do
      cache.remember("sess-1", nil, "session")
      expect(cache.allowed?("sess-1", nil)).to be(false)
    end
  end

  describe "rule-keyed matching (S3 — reference parity)" do
    it "covers a sibling command of the same dangerous class once approved" do
      cache.remember("sess-1", "shell:git push --force origin main", "session")
      # Same "git force push" class, different command → covered in-session.
      expect(cache.allowed?("sess-1", "shell:git push --force other")).to be(true)
    end

    it "does NOT let a dangerous-class approval cover an unrelated command" do
      cache.remember("sess-1", "shell:rm -rf /tmp/cache", "session")
      expect(cache.allowed?("sess-1", "shell:git status")).to be(false)
    end

    it "keeps a plain-command approval NARROW — a sibling is not covered" do
      cache.remember("sess-1", "shell:git status", "session")
      expect(cache.allowed?("sess-1", "shell:git status")).to be(true)
      expect(cache.allowed?("sess-1", "shell:git diff")).to be(false)
    end

    it "de-duplicates equivalent rules instead of growing unbounded" do
      cache.remember("sess-1", "shell:rm -rf /a", "session")
      cache.remember("sess-1", "shell:rm -rf /b", "session") # same class
      stored = cache.instance_variable_get(:@data)["sess-1"]
      expect(stored.size).to eq(1)
    end
  end

  describe "#forget!" do
    it "drops one session's entries when given a session id" do
      cache.remember("sess-1", "shell:ls", "session")
      cache.remember("sess-2", "shell:ls", "session")
      cache.forget!("sess-1")
      expect(cache.allowed?("sess-1", "shell:ls")).to be(false)
      expect(cache.allowed?("sess-2", "shell:ls")).to be(true)
    end

    it "wipes every session when called without an argument" do
      cache.remember("sess-1", "shell:ls", "session")
      cache.remember("sess-2", "shell:ls", "session")
      cache.forget!
      expect(cache.allowed?("sess-1", "shell:ls")).to be(false)
      expect(cache.allowed?("sess-2", "shell:ls")).to be(false)
    end
  end

  describe ".instance" do
    after { described_class.reset_singleton! }

    it "returns the same object across calls" do
      a = described_class.instance
      b = described_class.instance
      expect(a).to equal(b)
    end

    it "can be reset for test isolation" do
      first  = described_class.instance
      described_class.reset_singleton!
      second = described_class.instance
      expect(first).not_to equal(second)
    end
  end
end
