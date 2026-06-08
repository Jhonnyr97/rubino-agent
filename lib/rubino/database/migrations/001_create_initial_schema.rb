# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:sessions) do
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
    end

    create_table(:messages) do
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
    end

    add_index :messages, :session_id
    add_index :messages, :created_at

    create_table(:tool_calls) do
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
    end

    add_index :tool_calls, :session_id
    add_index :tool_calls, :tool_name

    create_table(:memories) do
      String :id, primary_key: true
      String :kind, null: false
      Text :content, null: false
      String :source_session_id
      Float :confidence, default: 1.0
      Text :metadata_json
      String :created_at, null: false
      String :updated_at, null: false
    end

    add_index :memories, :kind
    add_index :memories, :created_at

    create_table(:session_summaries) do
      String :id, primary_key: true
      String :session_id, null: false
      String :parent_summary_id
      Text :content, null: false
      Integer :token_count, default: 0
      String :created_at, null: false

      foreign_key [:session_id], :sessions, key: :id
    end

    add_index :session_summaries, :session_id

    create_table(:compactions) do
      String :id, primary_key: true
      String :source_session_id, null: false
      String :target_session_id, null: false
      String :previous_summary_id
      String :new_summary_id
      Integer :original_token_count
      Integer :compacted_token_count
      Integer :saved_token_count
      String :created_at, null: false
    end

    add_index :compactions, :source_session_id

    create_table(:jobs) do
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
    end

    add_index :jobs, :status
    add_index :jobs, :run_at
    add_index :jobs, [:status, :run_at]

    create_table(:job_runs) do
      String :id, primary_key: true
      String :job_id, null: false
      String :status, null: false
      String :started_at, null: false
      String :finished_at
      Text :error
      Text :metadata_json

      foreign_key [:job_id], :jobs, key: :id
    end

    add_index :job_runs, :job_id

    create_table(:events) do
      String :id, primary_key: true
      String :session_id
      String :type, null: false
      Text :payload_json
      String :created_at, null: false
    end

    add_index :events, :session_id
    add_index :events, :type
    add_index :events, :created_at
  end

  down do
    drop_table(:events)
    drop_table(:job_runs)
    drop_table(:jobs)
    drop_table(:compactions)
    drop_table(:session_summaries)
    drop_table(:memories)
    drop_table(:tool_calls)
    drop_table(:messages)
    drop_table(:sessions)
  end
end
