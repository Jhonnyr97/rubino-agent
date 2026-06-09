# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:runs) do
      String :id, primary_key: true
      String :session_id, null: false
      String :status, null: false, default: "queued" # queued|running|completed|failed|stopped
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

      foreign_key [:session_id], :sessions, key: :id
    end

    add_index :runs, :session_id
    add_index :runs, :status

    alter_table(:events) do
      add_column :run_id, String
      add_column :seq, Integer # per-session monotonic seq for SSE Last-Event-ID
    end

    add_index :events, :run_id
    add_index :events, %i[session_id seq]
  end

  down do
    alter_table(:events) do
      drop_column :seq
      drop_column :run_id
    end
    drop_table(:runs)
  end
end
