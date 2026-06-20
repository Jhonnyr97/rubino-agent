# frozen_string_literal: true

# SQUASHED BASELINE (v1) — the full Rubino schema in one idempotent migration.
#
# This collapses what used to be twelve incremental migrations (001 initial
# schema, 002 runs, 003 skill_states, 004 cron_jobs, 005 oauth_connections,
# 006 webhook_deliveries, 007 messages_fts, 008 memory_facts, 009 memory_graph,
# 010/011/012 sessions.owner_pid/memory_extracted_msg_id/cwd) into a single
# clean baseline. Rubino is a pre-public alpha with NO data-preservation
# requirement — fresh DBs are the only DBs — so the historical chain is gone and
# this file IS the schema. Future schema changes stack on top as 002, 003, …
#
# IDEMPOTENT BY CONSTRUCTION. Every object is created guarded so re-running the
# up block over a live schema is a clean no-op (no "already exists" backtrace):
#   * tables via `create_table?`;
#   * the FTS virtual tables and their triggers via `CREATE … IF NOT EXISTS`;
#   * EVERY index DECLARED INSIDE its `create_table?` block (`index …`) — NOT as
#     a standalone `add_index`. On SQLite, Sequel's `add_index … if_not_exists:`
#     is silently ignored (it never emits `CREATE INDEX IF NOT EXISTS`), so a
#     re-run of a standalone add_index raises "index … already exists". Inline
#     `index` declarations only run when the table itself is created, so they
#     inherit create_table?'s guard. (Index names are unchanged — Sequel derives
#     the same `<table>_<cols>_index` name either way.)
Sequel.migration do
  up do
    # ---- sessions (010/011/012 columns + H6 status/updated_at indexes) ------
    create_table?(:sessions) do
      String :id, primary_key: true
      String :parent_session_id
      String :source, null: false
      String :model
      String :provider
      String :title
      Text :summary
      String :status, null: false, default: "active"
      Integer :message_count, null: false, default: 0
      Integer :token_count, null: false, default: 0
      String :created_at, null: false
      String :updated_at, null: false
      String :ended_at
      Integer :owner_pid # 010: reap orphaned sessions
      String :memory_extracted_msg_id # 011: memory-extraction watermark
      String :cwd # 012: per-cwd resume scoping

      index :status # H6: session listing / status filter
      index :updated_at # H6: recency ordering / reaping
    end

    # ---- messages -----------------------------------------------------------
    create_table?(:messages) do
      String :id, primary_key: true
      String :session_id, null: false
      String :role, null: false
      Text :content
      String :tool_name
      String :tool_call_id
      Integer :token_count, default: 0
      Text :metadata_json
      String :created_at, null: false

      foreign_key [:session_id], :sessions, key: :id

      index :session_id
      index :created_at
      index %i[session_id role] # H6: role-filtered per-session reads
    end

    # ---- tool_calls ---------------------------------------------------------
    create_table?(:tool_calls) do
      String :id, primary_key: true
      String :session_id, null: false
      String :message_id
      String :tool_name, null: false
      Text :input_json
      Text :output
      String :status, null: false
      String :risk_level
      String :started_at
      String :finished_at
      Text :error

      foreign_key [:session_id], :sessions, key: :id

      index :session_id
      index :tool_name
    end

    # ---- memories -----------------------------------------------------------
    create_table?(:memories) do
      String :id, primary_key: true
      String :kind, null: false
      Text :content, null: false
      String :source_session_id
      Float :confidence, default: 1.0
      Text :metadata_json
      String :created_at, null: false
      String :updated_at, null: false

      index :kind
      index :created_at
    end

    # ---- session_summaries --------------------------------------------------
    create_table?(:session_summaries) do
      String :id, primary_key: true
      String :session_id, null: false
      String :parent_summary_id
      Text :content, null: false
      Integer :token_count, default: 0
      String :created_at, null: false

      foreign_key [:session_id], :sessions, key: :id

      index :session_id
    end

    # ---- compactions --------------------------------------------------------
    create_table?(:compactions) do
      String :id, primary_key: true
      String :source_session_id, null: false
      String :target_session_id, null: false
      String :previous_summary_id
      String :new_summary_id
      Integer :original_token_count
      Integer :compacted_token_count
      Integer :saved_token_count
      String :created_at, null: false

      index :source_session_id
    end

    # ---- jobs ---------------------------------------------------------------
    create_table?(:jobs) do
      String :id, primary_key: true
      String :type, null: false
      String :status, null: false, default: "queued"
      Integer :priority, null: false, default: 100
      Text :payload_json, null: false
      Integer :attempts, null: false, default: 0
      Integer :max_attempts, null: false, default: 3
      String :run_at, null: false
      String :locked_at
      String :locked_by
      Text :last_error
      String :created_at, null: false
      String :updated_at, null: false

      index :status
      index :run_at
      index %i[status run_at]
    end

    # ---- job_runs -----------------------------------------------------------
    create_table?(:job_runs) do
      String :id, primary_key: true
      String :job_id, null: false
      String :status, null: false
      String :started_at, null: false
      String :finished_at
      Text :error
      Text :metadata_json

      foreign_key [:job_id], :jobs, key: :id

      index :job_id
    end

    # ---- events (002 run_id/seq columns + indexes folded in) ----------------
    create_table?(:events) do
      String :id, primary_key: true
      String :session_id
      String :type, null: false
      Text :payload_json
      String :created_at, null: false
      String :run_id # 002: SSE run correlation
      Integer :seq # 002: per-session monotonic seq

      index :session_id
      index :type
      index :created_at
      index :run_id
      index %i[session_id seq]
    end

    # ---- runs (004 cron_job_id column folded in) ----------------------------
    create_table?(:runs) do
      String :id, primary_key: true
      String :session_id, null: false
      String :status, null: false, default: "queued"
      Text :input_text
      Text :attachments_json
      Text :skills_json
      String :model
      String :provider
      Integer :tokens_input, default: 0
      Integer :tokens_output, default: 0
      Text :error
      Boolean :stop_requested, null: false, default: false
      String :started_at
      String :finished_at
      String :created_at, null: false
      String :updated_at, null: false
      String :cron_job_id # 004: cron-triggered run linkage

      foreign_key [:session_id], :sessions, key: :id

      index :session_id
      index :status
      index :cron_job_id
    end

    # ---- skill_states -------------------------------------------------------
    create_table?(:skill_states) do
      String :name, primary_key: true
      Boolean :enabled, null: false, default: true
      String :updated_at, null: false
    end

    # ---- cron_jobs ----------------------------------------------------------
    create_table?(:cron_jobs) do
      String :id, primary_key: true
      String :name, null: false
      String :schedule, null: false
      Text :prompt, null: false
      Text :skills_json
      String :model
      String :provider
      String :deliver, null: false, default: "local"
      Boolean :enabled, null: false, default: true
      String :last_run_at
      String :last_run_id
      String :created_at, null: false
      String :updated_at, null: false

      index :enabled
      index :name
    end

    # ---- oauth_connections --------------------------------------------------
    create_table?(:oauth_connections) do
      String :id, primary_key: true
      String :provider, null: false
      String :account_id, null: false
      String :account_email
      Text :access_token, null: false        # encrypted
      Text :refresh_token                    # encrypted
      String :expires_at
      Text :scopes_json, null: false
      Text :metadata_json
      String :created_at, null: false
      String :updated_at, null: false

      unique %i[provider account_id]
      index :provider
    end

    # ---- webhook_deliveries -------------------------------------------------
    create_table?(:webhook_deliveries) do
      String :id, primary_key: true
      String :job_id
      String :run_id
      String :target_url, null: false
      String :request_id, null: false, unique: true
      String :payload_sha256, null: false
      Integer :attempt_count, null: false, default: 0
      String :status, null: false, default: "pending"
      Text :last_error
      Text :payload_json, null: false
      String :scheduled_at, null: false
      String :delivered_at
      String :created_at, null: false
      String :updated_at, null: false

      index :status
      index :scheduled_at
      index :job_id
      index :run_id
    end

    # ---- messages_fts (FTS5 external-content over messages) -----------------
    # Tokenizer is unicode61 with diacritic removal so "cafe"/"café" match. The
    # shadow tables (messages_fts_data/idx/docsize/config) are created implicitly
    # by CREATE VIRTUAL TABLE. Triggers keep the index in sync.
    run <<~SQL
      CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
        content,
        tool_name,
        role,
        content='messages',
        content_rowid='rowid',
        tokenize='unicode61 remove_diacritics 2'
      );
    SQL

    run <<~SQL
      CREATE TRIGGER IF NOT EXISTS messages_fts_ai AFTER INSERT ON messages BEGIN
        INSERT INTO messages_fts(rowid, content, tool_name, role)
        VALUES (new.rowid, new.content, new.tool_name, new.role);
      END;
    SQL

    run <<~SQL
      CREATE TRIGGER IF NOT EXISTS messages_fts_ad AFTER DELETE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, content, tool_name, role)
        VALUES ('delete', old.rowid, old.content, old.tool_name, old.role);
      END;
    SQL

    run <<~SQL
      CREATE TRIGGER IF NOT EXISTS messages_fts_au AFTER UPDATE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, content, tool_name, role)
        VALUES ('delete', old.rowid, old.content, old.tool_name, old.role);
        INSERT INTO messages_fts(rowid, content, tool_name, role)
        VALUES (new.rowid, new.content, new.tool_name, new.role);
      END;
    SQL

    # ---- memory_facts (SQLite memory store + FTS5) --------------------------
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

    # ---- memory_entities / memory_edges (graph-lite layer) ------------------
    create_table?(:memory_entities) do
      String :id, primary_key: true
      String :name, null: false # display form, first-seen casing
      String :name_norm, null: false # lowercased resolution key
      String :kind # person | tool | project | ...
      String :created_at, null: false
      String :updated_at, null: false

      index :name_norm, unique: true
    end

    create_table?(:memory_edges) do
      String :id, primary_key: true
      String :src_entity_id, null: false
      String :dst_entity_id, null: false
      String :relation, null: false # lowercased relation label
      String :source_fact_id # the fact this edge was derived from
      String :valid_from
      String :valid_to # set when superseded; live edge = NULL
      String :superseded_by # id of the edge that invalidated this
      String :created_at, null: false
      String :updated_at, null: false

      index :src_entity_id
      index :dst_entity_id
      index :valid_to
      index %i[src_entity_id dst_entity_id relation]
    end
  end

  down do
    run "DROP TRIGGER IF EXISTS memory_facts_fts_au"
    run "DROP TRIGGER IF EXISTS memory_facts_fts_ad"
    run "DROP TRIGGER IF EXISTS memory_facts_fts_ai"
    run "DROP TABLE IF EXISTS memory_facts_fts"
    drop_table?(:memory_edges)
    drop_table?(:memory_entities)
    drop_table?(:memory_facts)

    run "DROP TRIGGER IF EXISTS messages_fts_au"
    run "DROP TRIGGER IF EXISTS messages_fts_ad"
    run "DROP TRIGGER IF EXISTS messages_fts_ai"
    run "DROP TABLE IF EXISTS messages_fts"

    drop_table?(:webhook_deliveries)
    drop_table?(:oauth_connections)
    drop_table?(:cron_jobs)
    drop_table?(:skill_states)
    drop_table?(:runs)
    drop_table?(:events)
    drop_table?(:job_runs)
    drop_table?(:jobs)
    drop_table?(:compactions)
    drop_table?(:session_summaries)
    drop_table?(:memories)
    drop_table?(:tool_calls)
    drop_table?(:messages)
    drop_table?(:sessions)
  end
end
