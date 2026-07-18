# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::Memory::EntityExtractor do
  def extract(t) = described_class.extract(t).map(&:downcase)

  it "extracts identifiers, CamelCase/acronyms and proper nouns" do
    e = extract("AziendaOS uses rubino-agent as its coding agent, deployed on Incus VMs via Kamal.")
    expect(e).to include("aziendaos", "rubino-agent", "incus", "kamal")
  end

  it "keeps CamelCase and acronym tech names" do
    expect(extract("The user prefers RSpec and tests via GLiNER on the API.")).to include("rspec", "gliner", "api")
  end

  it "drops sentence-initial common words and pronouns (not entities)" do
    e = extract("Also, please remember that the user works here. This is important.")
    expect(e).not_to include("also", "please", "remember", "this", "user")
  end

  it "dedupes by normalized name, keeping first surface form" do
    expect(described_class.extract("Kamal deploys it; Kamal again")).to eq(["Kamal"])
  end

  it "returns [] for empty or entity-free text" do
    expect(described_class.extract("")).to eq([])
    expect(described_class.extract("it just works fine here")).to eq([])
  end

  it "bounds the number of entities" do
    text = (1..40).map { |i| "Node#{i}" }.join(" ")
    expect(described_class.extract(text).size).to be <= described_class::MAX_ENTITIES
  end
end
