# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Sessions
        # POST /v1/sessions/:id/retry
        # Deletes the last user message and everything after it, then enqueues a
        # fresh run with the same input. Returns 202 with the new run id.
        #
        # @return [[Integer, Hash]] 202 + { run_id, session_id, status: "running" }.
        # @raise [Rubino::NotFoundError] when the session does not exist.
        # @raise [Rubino::ConflictError] when the session has no user message to retry.
        class RetryOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts alternate collaborators (session repo, message store, run repo, executor) for tests.
          def initialize(session_repository: nil, message_store: nil, run_repository: nil, executor: nil)
            @session_repo = session_repository || ::Rubino::Session::Repository.new
            @message_store = message_store || ::Rubino::Session::Store.new
            @run_repo = run_repository || ::Rubino::Run::Repository.new
            @executor = executor || ::Rubino::Run::Executor.new
          end

          def call(request)
            session_id = request.params.fetch("id")
            raise NotFoundError.new("session", session_id) unless @session_repo.find(session_id)

            last_user = @message_store.last_for_role(session_id, "user")
            raise ConflictError, "no user message to retry" unless last_user

            @message_store.delete_from_inclusive(session_id, from_id: last_user.id)

            run = @run_repo.create(session_id: session_id, input_text: last_user.content)
            @executor.start(run)

            [202, { run_id: run[:id], session_id: session_id, status: "running" }]
          end
        end
      end
    end
  end
end
