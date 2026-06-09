# frozen_string_literal: true

RSpec.describe Rubino::Memory::Deduplicator do
  let(:db_connection) { test_database }
  let(:store) { Rubino::Memory::Store.new(db: db_connection.db) }
  let(:deduplicator) { described_class.new(store: store) }

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
