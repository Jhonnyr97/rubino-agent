# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:webhook_deliveries) do
      String :id, primary_key: true
      String :job_id
      String :run_id
      String :target_url, null: false
      # request_id (X-Rubino-Delivery-Id) is unique across delivery rows so
      # a crash-then-restart cannot create two pending rows for the same logical
      # attempt; the resume hook keys off this column.
      String :request_id, null: false, unique: true
      String :payload_sha256, null: false
      Integer :attempt_count, null: false, default: 0
      String :status, null: false, default: "pending"   # pending|delivered|failed|dead
      Text :last_error
      Text :payload_json, null: false
      String :scheduled_at, null: false
      String :delivered_at
      String :created_at, null: false
      String :updated_at, null: false
    end

    add_index :webhook_deliveries, :status
    add_index :webhook_deliveries, :scheduled_at
    add_index :webhook_deliveries, :job_id
    add_index :webhook_deliveries, :run_id
  end

  down do
    drop_table(:webhook_deliveries)
  end
end
