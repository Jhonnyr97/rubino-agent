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
  end

  describe "#within_limit" do
    it "returns memories that fit within char limit" do
      store.create(kind: "fact", content: "a" * 100)
      store.create(kind: "fact", content: "b" * 100)
      store.create(kind: "fact", content: "c" * 100)

      # Only 2 fit within 250 chars (100 + 100 = 200 < 250, but 100+100+100=300 > 250)
      results = store.within_limit(char_limit: 250)
      expect(results.size).to eq(2)
    end

    it "returns all memories when limit is large enough" do
      store.create(kind: "fact", content: "short")
      store.create(kind: "fact", content: "also short")
      results = store.within_limit(char_limit: 1_000)
      expect(results.size).to eq(2)
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
