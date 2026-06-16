# frozen_string_literal: true

require "spec_helper"
require "sequel"
require "sequel/extensions/migration"

# The squashed baseline wires FTS5 over the messages table. It must:
# 1. Create the messages_fts virtual table after running migrations.
# 2. Auto-sync via triggers on subsequent inserts (so a row inserted after
#    migrating is immediately searchable).
RSpec.describe "messages_fts (squashed baseline)" do
  let(:connection) { Rubino::Database::Connection.new(":memory:") }

  it "creates the messages_fts virtual table after migrating" do
    Rubino::Database::Migrator.new(connection).migrate!
    expect(connection.db.tables).to include(:messages_fts)
  end

  it "uses an FTS5 virtual table (snippet() is callable)" do
    Rubino::Database::Migrator.new(connection).migrate!
    db = connection.db

    db[:sessions].insert(
      id: "s1", source: "test", status: "active",
      message_count: 0, token_count: 0,
      created_at: Time.now.utc.iso8601, updated_at: Time.now.utc.iso8601
    )
    db[:messages].insert(
      id: "m1", session_id: "s1", role: "user",
      content: "the quick brown fox jumps", created_at: Time.now.utc.iso8601
    )

    rows = db.fetch(
      "SELECT snippet(messages_fts, 0, '<b>', '</b>', '...', 10) AS s " \
      "FROM messages_fts WHERE messages_fts MATCH ?",
      "quick"
    ).all
    expect(rows.first[:s]).to include("<b>quick</b>")
  end

  it "keeps the index in sync via triggers on insert" do
    Rubino::Database::Migrator.new(connection).migrate!
    db = connection.db

    db[:sessions].insert(
      id: "s1", source: "test", status: "active",
      message_count: 0, token_count: 0,
      created_at: Time.now.utc.iso8601, updated_at: Time.now.utc.iso8601
    )
    db[:messages].insert(
      id: "m1", session_id: "s1", role: "user",
      content: "needle in the haystack", created_at: Time.now.utc.iso8601
    )

    matches = db.fetch(
      "SELECT m.id FROM messages_fts JOIN messages m ON m.rowid = messages_fts.rowid " \
      "WHERE messages_fts MATCH ?",
      "needle"
    ).all
    expect(matches.map { |r| r[:id] }).to eq(["m1"])
  end
end
