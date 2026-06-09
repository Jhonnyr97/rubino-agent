# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module OAuth
        # Strips secret fields from connection rows before they leave the API.
        # Tokens never go on the wire — clients use them implicitly through
        # tools, not directly.
        module Serializer
          PUBLIC_FIELDS = %i[id provider account_id account_email expires_at scopes metadata created_at
                             updated_at].freeze

          def self.call(connection)
            connection.slice(*PUBLIC_FIELDS)
          end
        end
      end
    end
  end
end
