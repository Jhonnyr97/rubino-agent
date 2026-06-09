# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:cron_jobs) do
      String :id, primary_key: true
      String :name, null: false
      String :schedule, null: false # cron expression
      Text :prompt, null: false
      Text :skills_json
      String :model
      String :provider
      String :deliver, null: false, default: "local" # local|webhook
      Boolean :enabled, null: false, default: true
      String :last_run_at
      String :last_run_id
      String :created_at, null: false
      String :updated_at, null: false
    end

    add_index :cron_jobs, :enabled
    add_index :cron_jobs, :name

    alter_table(:runs) do
      add_column :cron_job_id, String
    end
    add_index :runs, :cron_job_id
  end

  down do
    alter_table(:runs) do
      drop_column :cron_job_id
    end
    drop_table(:cron_jobs)
  end
end
