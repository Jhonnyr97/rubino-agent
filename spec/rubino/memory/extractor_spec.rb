# frozen_string_literal: true

RSpec.describe Rubino::Memory::Extractor do
  let(:db_connection) { test_database }
  let(:store) { Rubino::Memory::Store.new(db: db_connection.db) }
  let(:extractor) { described_class.new(store: store) }

  before { db_connection.db[:memories].delete }

  describe "#extract_from_content" do
    it "extracts a preference when a preference pattern matches" do
      memories = extractor.extract_from_content("I prefer dark themes for editors")
      expect(memories.size).to eq(1)
      expect(memories.first[:kind]).to eq("preference")
    end

    it "extracts a technical_decision when a decision pattern matches" do
      memories = extractor.extract_from_content("We decided to use PostgreSQL for storage")
      expect(memories.size).to eq(1)
      expect(memories.first[:kind]).to eq("technical_decision")
    end

    it "extracts both kinds when both patterns match" do
      memories = extractor.extract_from_content(
        "I prefer terse replies, and we decided to ship the MVP first"
      )
      kinds = memories.map { |m| m[:kind] }
      expect(kinds).to include("preference", "technical_decision")
    end

    it "returns no memories for content without trigger patterns" do
      memories = extractor.extract_from_content("The weather is nice today")
      expect(memories).to be_empty
    end

    it "skips duplicates via the deduplicator" do
      extractor.extract_from_content("I prefer dark themes")
      memories = extractor.extract_from_content("I prefer dark themes")
      expect(memories).to be_empty
    end

    it "truncates extracted content to 500 chars" do
      # Use whitespace so the slice avoids tripping ThreatScanner's
      # contiguous-base64 heuristic (>=200 a/b/c/.../0-9/+/ chars).
      long = "I prefer " + ("word " * 250).strip
      memories = extractor.extract_from_content(long)
      expect(memories.first[:content].length).to be <= 501
    end
  end
end
