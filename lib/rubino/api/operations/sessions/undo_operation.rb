# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Sessions
        # POST /v1/sessions/:id/undo
        # Removes the last user message and everything after it (no re-run).
        # Returns the number of messages deleted.
        #
        # @raise [Rubino::NotFoundError] when the session does not exist.
        # @raise [Rubino::ConflictError] when the session has no user message to undo.
        class UndoOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate session repository and message store for tests.
          def initialize(session_repository: nil, message_store: nil)
            @session_repo = session_repository || ::Rubino::Session::Repository.new
            @message_store = message_store || ::Rubino::Session::Store.new
          end

          def call(request)
            session_id = request.params.fetch("id")
            raise NotFoundError.new("session", session_id) unless @session_repo.find(session_id)

            last_user = @message_store.last_for_role(session_id, "user")
            raise ConflictError, "nothing to undo" unless last_user

            removed = @message_store.delete_from_inclusive(session_id, from_id: last_user.id)
            [200, { removed_messages: removed }]
          end
        end
      end
    end
  end
end
