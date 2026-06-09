# frozen_string_literal: true

RSpec.describe Rubino::Memory::Retriever do
  let(:db_connection) { test_database }
  let(:config) do
    test_configuration("memory" => {
                         "enabled" => true,
                         "user_profile_enabled" => true,
                         "project_context_enabled" => true,
                         "memory_char_limit" => 1_000,
                         "user_char_limit" => 200
                       })
  end
  let(:store) { Rubino::Memory::Store.new(db: db_connection.db, config: config) }
  let(:retriever) { described_class.new(store: store, config: config) }

  before { db_connection.db[:memories].delete }

  describe "#user_profile" do
    it "returns nil when feature is disabled" do
      disabled = test_configuration("memory" => { "user_profile_enabled" => false })
      r = described_class.new(store: store, config: disabled)
      expect(r.user_profile).to be_nil
    end

    it "concatenates user_profile memories" do
      store.create(kind: "user_profile", content: "prefers terse output")
      store.create(kind: "user_profile", content: "speaks Italian")
      expect(retriever.user_profile).to include("prefers terse output")
      expect(retriever.user_profile).to include("speaks Italian")
    end

    it "truncates output to the configured user char limit" do
      store.create(kind: "user_profile", content: "u" * 150)
      # next write would breach the budget — bypass for the test via direct insert
      db_connection.db[:memories].insert(
        id: SecureRandom.uuid,
        kind: "user_profile",
        content: "v" * 150,
        confidence: 1.0,
        created_at: Time.now.utc.iso8601,
        updated_at: Time.now.utc.iso8601
      )
      expect(retriever.user_profile.length).to eq(200)
    end
  end

  describe "#project_context" do
    it "returns nil when no project_context memories exist" do
      expect(retriever.project_context).to be_nil
    end

    it "returns concatenated project_context memories" do
      store.create(kind: "project_context", content: "uses Rails 8")
      store.create(kind: "project_context", content: "deploys via Capistrano")
      expect(retriever.project_context).to include("Rails 8")
      expect(retriever.project_context).to include("Capistrano")
    end
  end

  describe "#for_prompt" do
    it "returns a hash with user_profile, project_context, and general keys" do
      store.create(kind: "user_profile", content: "tabs over spaces")
      store.create(kind: "project_context", content: "uses zsh")
      store.create(kind: "fact", content: "ruby is great")

      result = retriever.for_prompt
      expect(result.keys).to contain_exactly(:user_profile, :project_context, :general)
      expect(result[:user_profile]).to include("tabs over spaces")
      expect(result[:project_context]).to include("zsh")
      expect(result[:general].map { |m| m[:content] }).to include("ruby is great")
    end
  end

  describe "#relevant_for_session" do
    it "returns memories that fit the char budget" do
      # Mixed content avoids the ThreatScanner contiguous-base64 heuristic.
      store.create(kind: "fact", content: ("alpha " * 60).strip)
      store.create(kind: "fact", content: ("beta "  * 60).strip)
      results = retriever.relevant_for_session("any-session-id")
      expect(results.size).to be >= 1
    end
  end
end
