# frozen_string_literal: true

RSpec.describe Rubino::Session::Store do
  let(:db_connection) { test_database }
  let(:store)        { described_class.new(db: db_connection.db) }
  let(:session_repo) { Rubino::Session::Repository.new(db: db_connection.db) }
  let(:session)      { session_repo.create(source: "test") }

  before do
    db = db_connection.db
    db[:events].delete
    db[:tool_calls].delete
    db[:messages].delete
    db[:runs].delete if db.table_exists?(:runs)
    db[:sessions].delete
  end

  describe "#create" do
    it "creates and persists a message" do
      msg = store.create(session_id: session[:id], role: "user", content: "Hello world")
      expect(msg.id).not_to be_nil
      expect(msg.role).to eq("user")
      expect(msg.content).to eq("Hello world")
    end
  end

  describe "#for_session" do
    it "returns messages in chronological order" do
      store.create(session_id: session[:id], role: "user",      content: "first")
      store.create(session_id: session[:id], role: "assistant", content: "second")
      store.create(session_id: session[:id], role: "user",      content: "third")

      messages = store.for_session(session[:id])
      expect(messages.size).to eq(3)
      expect(messages.map(&:content)).to eq(%w[first second third])
    end

    # Regression: created_at is second-precision. Three rows inserted in the
    # same second (typical for "assistant preamble → tool result → assistant
    # follow-up" inside a single agent loop iteration) used to come back in
    # an undefined order, breaking the resumed transcript.
    it "breaks created_at ties on rowid to preserve insertion order" do
      same_ts = "2026-01-01T00:00:00Z"
      [
        ["assistant", "preamble"],
        ["tool",      "tool out"],
        ["assistant", "follow-up"]
      ].each do |role, content|
        db_connection.db[:messages].insert(
          id: SecureRandom.uuid,
          session_id: session[:id],
          role: role,
          content: content,
          created_at: same_ts
        )
      end

      messages = store.for_session(session[:id])
      expect(messages.map(&:content)).to eq(["preamble", "tool out", "follow-up"])
    end
  end

  describe "#count" do
    it "returns the correct message count" do
      store.create(session_id: session[:id], role: "user",      content: "a")
      store.create(session_id: session[:id], role: "assistant", content: "b")
      expect(store.count(session[:id])).to eq(2)
    end
  end

  describe "#recent" do
    it "returns the N most recent messages in order" do
      5.times { |i| store.create(session_id: session[:id], role: "user", content: "msg#{i}") }
      recent = store.recent(session[:id], count: 2)
      expect(recent.size).to eq(2)
      expect(recent.last.content).to eq("msg4")
    end

    it "returns all messages when count exceeds total" do
      store.create(session_id: session[:id], role: "user", content: "only")
      expect(store.recent(session[:id], count: 10).size).to eq(1)
    end
  end

  describe "#token_sum" do
    it "returns sum of token_count" do
      store.create(session_id: session[:id], role: "user", content: "hi", token_count: 5)
      store.create(session_id: session[:id], role: "assistant", content: "hello", token_count: 10)
      expect(store.token_sum(session[:id])).to eq(15)
    end

    it "returns 0 when no messages" do
      expect(store.token_sum(session[:id])).to eq(0)
    end
  end
end
