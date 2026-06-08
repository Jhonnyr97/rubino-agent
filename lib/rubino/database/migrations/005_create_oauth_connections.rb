# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:oauth_connections) do
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
    end

    add_index :oauth_connections, :provider
  end

  down do
    drop_table(:oauth_connections)
  end
end
