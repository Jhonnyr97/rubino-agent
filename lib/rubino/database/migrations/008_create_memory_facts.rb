# frozen_string_literal: true

# Tiny-Zep memory store for Memory::Backends::Sqlite.
#
# One ATOMIC declarative fact per row, with bi-temporal validity: `valid_from`
# is when the fact became true in the world, `valid_to` is set when a later,
# contradicting fact supersedes it (Graphiti-style edge invalidation). A "live"
# fact is `valid_to IS NULL`; superseded rows are kept (historical record), just
# excluded from injection. `entities_json` carries lightweight tags so a graph
# slice can be layered on later without a schema change.
#
# A companion FTS5 virtual table mirrors `text` (+ entities) for BM25 recall,
# kept in sync by triggers — same external-content pattern as messages_fts.
Sequel.migration do
  up do
    create_table?(:memory_facts) do
      String  :id, primary_key: true
      Text    :text, null: false
      String  :kind, null: false
      Text    :entities_json
      String  :source_session_id
      Float   :confidence, default: 1.0
      String  :valid_from
      String  :valid_to
      String  :superseded_by
      File    :embedding
      String  :created_at, null: false
      String  :updated_at, null: false

      index :kind
      index :valid_to
    end

    run <<~SQL
      CREATE VIRTUAL TABLE IF NOT EXISTS memory_facts_fts USING fts5(
        text,
        entities,
        content='memory_facts',
        content_rowid='rowid',
        tokenize='porter unicode61 remove_diacritics 2'
      );
    SQL

    run <<~SQL
      CREATE TRIGGER IF NOT EXISTS memory_facts_fts_ai AFTER INSERT ON memory_facts BEGIN
        INSERT INTO memory_facts_fts(rowid, text, entities)
        VALUES (new.rowid, new.text, new.entities_json);
      END;
    SQL

    run <<~SQL
      CREATE TRIGGER IF NOT EXISTS memory_facts_fts_ad AFTER DELETE ON memory_facts BEGIN
        INSERT INTO memory_facts_fts(memory_facts_fts, rowid, text, entities)
        VALUES ('delete', old.rowid, old.text, old.entities_json);
      END;
    SQL

    run <<~SQL
      CREATE TRIGGER IF NOT EXISTS memory_facts_fts_au AFTER UPDATE ON memory_facts BEGIN
        INSERT INTO memory_facts_fts(memory_facts_fts, rowid, text, entities)
        VALUES ('delete', old.rowid, old.text, old.entities_json);
        INSERT INTO memory_facts_fts(rowid, text, entities)
        VALUES (new.rowid, new.text, new.entities_json);
      END;
    SQL
  end

  down do
    run "DROP TRIGGER IF EXISTS memory_facts_fts_au"
    run "DROP TRIGGER IF EXISTS memory_facts_fts_ad"
    run "DROP TRIGGER IF EXISTS memory_facts_fts_ai"
    run "DROP TABLE IF EXISTS memory_facts_fts"
    drop_table?(:memory_facts)
  end
end
