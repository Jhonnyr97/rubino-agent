# frozen_string_literal: true

RSpec.describe Rubino::Memory::Store do
  let(:db_connection) { test_database }
  let(:store) { described_class.new(db: db_connection.db) }

  # Ensure clean state for every example
  before { db_connection.db[:memories].delete }

  describe "#create" do
    it "creates a memory with valid kind" do
      memory = store.create(kind: "fact", content: "Ruby is great")
      expect(memory[:id]).not_to be_nil
      expect(memory[:kind]).to eq("fact")
      expect(memory[:content]).to eq("Ruby is great")
    end

    it "raises for invalid kind" do
      expect { store.create(kind: "invalid", content: "test") }.to raise_error(Rubino::Error)
    end

    it "stores default confidence of 1.0" do
      memory = store.create(kind: "fact", content: "test")
      expect(memory[:confidence]).to eq(1.0)
    end

    # R4-N3 — a NUL byte (valid UTF-8) makes the SQLite3 driver raise
    # "unrecognized token" so the row never persists; scrub_utf8 at the write
    # seam strips it (and repairs invalid encoding) so the fact still stores.
    it "strips a NUL byte from content so the row persists" do
      memory = store.create(kind: "fact", content: "before\x00after")
      expect(memory[:content]).to eq("beforeafter")
      expect(store.find(memory[:id])[:content]).to eq("beforeafter")
    end

    it "coerces non-UTF-8 content to valid UTF-8 instead of failing to persist" do
      memory = store.create(kind: "fact", content: (+"caf\xE9").force_encoding("ASCII-8BIT"))
      expect(memory[:id]).not_to be_nil
      expect(memory[:content].encoding).to eq(Encoding::UTF_8)
      expect(memory[:content].valid_encoding?).to be(true)
    end
  end

  # #Y4 — saving the same fact twice used to mint two identical rows; the
  # write seam now dedups exact/normalized-verbatim repeats (idempotent).
  describe "#create verbatim dedup (#Y4)" do
    it "keeps a single row when identical content is saved twice" do
      first  = store.create(kind: "fact", content: "Ruby is great")
      second = store.create(kind: "fact", content: "Ruby is great")

      expect(second[:id]).to eq(first[:id])
      expect(store.by_kind("fact").size).to eq(1)
    end

    it "dedups a whitespace/case variant of the same fact" do
      first  = store.create(kind: "fact", content: "Ruby is great")
      second = store.create(kind: "fact", content: "  ruby   IS  Great ")

      expect(second[:id]).to eq(first[:id])
      expect(store.by_kind("fact").size).to eq(1)
    end

    it "still stores a genuinely different fact as its own row" do
      store.create(kind: "fact", content: "Ruby is great")
      store.create(kind: "fact", content: "Python is fine too")

      expect(store.by_kind("fact").size).to eq(2)
    end
  end

  # R1: a write carrying a credential must be REFUSED — the secret must never
  # land in the store (it would be persisted to disk and re-injected into every
  # future system prompt). Asserts both the refusal AND an empty table.
  describe "#create with a secret (R1)" do
    [
      ["sk-proj key", "remember sk-proj-FAKE0000000000000000abcd"],
      ["AWS secret near context",
       'aws_secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"'],
      ["generic high-entropy", "creds Zx9Kp2Lq7Wm4Rt8Yn3Bv6Cd1Fg5Hj0"]
    ].each do |label, sample|
      it "refuses and never persists: #{label}" do
        expect { store.create(kind: "fact", content: sample) }
          .to raise_error(Rubino::Memory::Store::ThreatDetectedError) { |e| expect(e.threat).to eq("secret_detected") }
        expect(db_connection.db[:memories].count).to eq(0)
      end
    end

    it "saves a normal fact, a UUID and a git SHA unchanged (no false positive)" do
      %w[fact fact fact].zip([
                               "Ruby 3.3.3 is the project version",
                               "session 550e8400-e29b-41d4-a716-446655440000",
                               "commit ff6c8958c0de1234567890abcdef1234567890ab"
                             ]).each do |kind, content|
        mem = store.create(kind: kind, content: content)
        expect(mem[:content]).to eq(content)
      end
      expect(db_connection.db[:memories].count).to eq(3)
    end
  end

  describe "#list" do
    it "returns all memories ordered by creation (newest first)" do
      store.create(kind: "fact",       content: "first")
      store.create(kind: "preference", content: "second")
      expect(store.list.size).to eq(2)
    end

    it "filters by kind" do
      store.create(kind: "fact",       content: "a fact")
      store.create(kind: "preference", content: "a preference")
      facts = store.list(kind: "fact")
      expect(facts.size).to eq(1)
      expect(facts.first[:kind]).to eq("fact")
    end
  end

  describe "#find" do
    it "finds by full ID" do
      memory = store.create(kind: "fact", content: "find me")
      expect(store.find(memory[:id])).not_to be_nil
    end

    it "finds by prefix" do
      memory = store.create(kind: "fact", content: "find by prefix")
      expect(store.find(memory[:id][0..7])).not_to be_nil
    end
  end

  describe "#delete" do
    it "deletes a memory and returns true" do
      memory = store.create(kind: "fact", content: "temp")
      expect(store.delete(memory[:id])).to be true
      expect(store.find(memory[:id])).to be_nil
    end

    it "returns false for unknown ID" do
      expect(store.delete("unknown-id-00000000")).to be false
    end

    # #416: delete("") used to LIKE-match the `%` wildcard → wiped every row and
    # reported success. A blank id must delete NOTHING and report failure.
    it "delete(\"\") deletes NOTHING and reports failure (no mass-wipe)" do
      store.create(kind: "fact", content: "keep me 1")
      store.create(kind: "fact", content: "keep me 2")
      expect(store.count).to eq(2)
      expect(store.delete("")).to be false
      expect(store.count).to eq(2)
    end

    it "find(\"\") returns nil instead of an arbitrary first row" do
      store.create(kind: "fact", content: "present")
      expect(store.find("")).to be_nil
    end
  end

  describe "#count" do
    it "returns total memory count" do
      store.create(kind: "fact", content: "one")
      store.create(kind: "fact", content: "two")
      expect(store.count).to eq(2)
    end
  end
end
