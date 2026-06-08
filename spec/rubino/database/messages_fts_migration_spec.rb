# frozen_string_literal: true

require "spec_helper"
require "sequel"
require "sequel/extensions/migration"

# Migration 007 wires FTS5 over the messages table. It must:
# 1. Create the messages_fts virtual table after running migrations.
# 2. Backfill any rows that already existed when the migration runs (this is
#    what makes the migration safe on an upgraded install).
# 3. Auto-sync via triggers on subsequent inserts.
RSpec.describe "messages_fts migration (007)" do
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

  it "backfills rows that existed before migration 007 ran" do
    # Run up through migration 006 only — leaves the messages table populated
    # without the FTS index, mimicking an upgrade on an existing install.
    db = connection.db
    Sequel::Migrator.run(db, Rubino::Database::Migrator::MIGRATIONS_PATH, target: 6)

    db[:sessions].insert(
      id: "s1", source: "test", status: "active",
      message_count: 0, token_count: 0,
      created_at: Time.now.utc.iso8601, updated_at: Time.now.utc.iso8601
    )
    db[:messages].insert(
      id: "m1", session_id: "s1", role: "user",
      content: "preexisting needle in the haystack", created_at: Time.now.utc.iso8601
    )

    Sequel::Migrator.run(db, Rubino::Database::Migrator::MIGRATIONS_PATH, target: 7)

    matches = db.fetch(
      "SELECT m.id FROM messages_fts JOIN messages m ON m.rowid = messages_fts.rowid " \
      "WHERE messages_fts MATCH ?",
      "needle"
    ).all
    expect(matches.map { |r| r[:id] }).to eq(["m1"])
  end
end
