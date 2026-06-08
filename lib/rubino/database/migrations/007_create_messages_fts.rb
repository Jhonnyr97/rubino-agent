# frozen_string_literal: true

# Full-text search over the `messages` table.
#
# Uses an external-content FTS5 table (content='messages') so the index never
# duplicates the body — FTS5 reaches into `messages` via rowid for each match.
# Triggers keep the index in sync on insert/update/delete; tokenizer is
# unicode61 with diacritic removal so "cafe"/"café" match.
Sequel.migration do
  up do
    run <<~SQL
      CREATE VIRTUAL TABLE messages_fts USING fts5(
        content,
        tool_name,
        role,
        content='messages',
        content_rowid='rowid',
        tokenize='unicode61 remove_diacritics 2'
      );
    SQL

    run <<~SQL
      CREATE TRIGGER messages_fts_ai AFTER INSERT ON messages BEGIN
        INSERT INTO messages_fts(rowid, content, tool_name, role)
        VALUES (new.rowid, new.content, new.tool_name, new.role);
      END;
    SQL

    run <<~SQL
      CREATE TRIGGER messages_fts_ad AFTER DELETE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, content, tool_name, role)
        VALUES ('delete', old.rowid, old.content, old.tool_name, old.role);
      END;
    SQL

    run <<~SQL
      CREATE TRIGGER messages_fts_au AFTER UPDATE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, content, tool_name, role)
        VALUES ('delete', old.rowid, old.content, old.tool_name, old.role);
        INSERT INTO messages_fts(rowid, content, tool_name, role)
        VALUES (new.rowid, new.content, new.tool_name, new.role);
      END;
    SQL

    # Backfill any rows already present (no-op on a fresh DB; required when
    # this migration runs against an existing install).
    run <<~SQL
      INSERT INTO messages_fts(rowid, content, tool_name, role)
      SELECT rowid, content, tool_name, role FROM messages;
    SQL
  end

  down do
    run "DROP TRIGGER IF EXISTS messages_fts_au"
    run "DROP TRIGGER IF EXISTS messages_fts_ad"
    run "DROP TRIGGER IF EXISTS messages_fts_ai"
    run "DROP TABLE IF EXISTS messages_fts"
  end
end
