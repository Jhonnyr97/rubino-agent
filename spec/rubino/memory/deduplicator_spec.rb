# frozen_string_literal: true

RSpec.describe Rubino::Memory::Deduplicator do
  let(:db_connection) { test_database }
  let(:store) { Rubino::Memory::Store.new(db: db_connection.db) }
  let(:deduplicator) { described_class.new(store: store) }

  describe ".normalize_verbatim (#Y4)" do
    it "collapses whitespace, trims, and case-folds" do
      expect(described_class.normalize_verbatim("  Ruby   IS\nGreat ")).to eq("ruby is great")
    end

    it "equates whitespace/case variants of the same fact" do
      a = described_class.normalize_verbatim("User lives in Lima.")
      b = described_class.normalize_verbatim("  user   LIVES in  lima. ")
      expect(a).to eq(b)
    end

    it "keeps genuinely different facts distinct" do
      a = described_class.normalize_verbatim("User lives in Lima.")
      b = described_class.normalize_verbatim("User lives in Cusco.")
      expect(a).not_to eq(b)
    end

    it "normalizes nil/blank to an empty string" do
      expect(described_class.normalize_verbatim(nil)).to eq("")
      expect(described_class.normalize_verbatim("   ")).to eq("")
    end
  end

  describe "#duplicate?" do
    it "detects duplicate content" do
      store.create(kind: "fact", content: "Ruby is a programming language")
      expect(deduplicator.duplicate?(
               kind: "fact",
               content: "Ruby is a programming language"
             )).to be true
    end

    it "detects highly similar content" do
      store.create(kind: "fact", content: "The user prefers dark themes for editors")
      expect(deduplicator.duplicate?(
               kind: "fact",
               content: "The user prefers dark themes for their editors"
             )).to be true
    end

    it "does not flag different content" do
      store.create(kind: "fact", content: "Ruby is great")
      expect(deduplicator.duplicate?(
               kind: "fact",
               content: "Python is used for data science"
             )).to be false
    end
  end
end
