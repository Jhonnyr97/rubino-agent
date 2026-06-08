# frozen_string_literal: true

# Specs for Session::SummaryStore — the single owner of the
# `session_summaries` table. Compaction summaries were previously read/written
# from three places with diverging Sequel blocks; the contract that matters
# here is (1) "latest" is the newest created_at and (2) every insert chains
# parent_summary_id to the prior row so lineage never drifts by writer.

RSpec.describe Rubino::Session::SummaryStore do
  let(:db_connection) { test_database }
  let(:db) { db_connection.db }
  let(:repo) { Rubino::Session::Repository.new(db: db) }
  let(:session) { repo.create(source: "test", model: "m", provider: "p") }
  let(:store) { described_class.new(db: db) }

  describe "#latest / #latest_content / #latest_id" do
    it "returns nil when no summary exists" do
      expect(store.latest(session[:id])).to be_nil
      expect(store.latest_content(session[:id])).to be_nil
      expect(store.latest_id(session[:id])).to be_nil
    end

    it "returns the most recent summary by created_at" do
      db[:session_summaries].insert(
        id: "old", session_id: session[:id], content: "first",
        token_count: 1, created_at: "2026-01-01T00:00:00Z"
      )
      db[:session_summaries].insert(
        id: "new", session_id: session[:id], content: "second",
        token_count: 1, created_at: "2026-02-01T00:00:00Z"
      )

      expect(store.latest_id(session[:id])).to eq("new")
      expect(store.latest_content(session[:id])).to eq("second")
    end

    it "scopes to the given session" do
      other = repo.create(source: "test")
      db[:session_summaries].insert(
        id: "x", session_id: other[:id], content: "elsewhere",
        token_count: 1, created_at: "2026-03-01T00:00:00Z"
      )

      expect(store.latest_content(session[:id])).to be_nil
    end
  end

  describe "#insert" do
    it "persists the summary and returns its id" do
      id = store.insert(session_id: session[:id], content: "hello world")

      row = db[:session_summaries].where(id: id).first
      expect(row[:content]).to eq("hello world")
      expect(row[:session_id]).to eq(session[:id])
      expect(row[:created_at]).not_to be_nil
    end

    it "estimates token_count from content length (~4 chars/token)" do
      id = store.insert(session_id: session[:id], content: "a" * 40)
      expect(db[:session_summaries].where(id: id).first[:token_count]).to eq(10)
    end

    it "chains parent_summary_id to the current latest summary" do
      first_id = store.insert(session_id: session[:id], content: "first")
      second_id = store.insert(session_id: session[:id], content: "second")

      first = db[:session_summaries].where(id: first_id).first
      second = db[:session_summaries].where(id: second_id).first

      expect(first[:parent_summary_id]).to be_nil
      expect(second[:parent_summary_id]).to eq(first_id)
    end
  end
end
