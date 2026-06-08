# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:skill_states) do
      String :name, primary_key: true
      Boolean :enabled, null: false, default: true
      String :updated_at, null: false
    end
  end

  down do
    drop_table(:skill_states)
  end
end
