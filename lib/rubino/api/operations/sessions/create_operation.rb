# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Sessions
        # POST /v1/sessions
        # Creates a session row (source="api") and returns its serialized form.
        #
        # @return [[Integer, Hash]] 201 + session payload.
        # @raise [Rubino::ValidationError] when the body fails Schemas::CreateSession.
        class CreateOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate repository for tests.
          def initialize(repository: nil)
            @repository = repository || ::Rubino::Session::Repository.new
          end

          def call(request)
            attrs = request.validate!(Schemas::CreateSession)
            session = @repository.create(
              source: "api",
              title: attrs[:title],
              parent_session_id: attrs[:parent_id]
            )
            [201, serialize(session)]
          end

          private

          def serialize(session)
            {
              id: session[:id],
              title: session[:title],
              parent_id: session[:parent_session_id],
              created_at: session[:created_at]
            }
          end
        end
      end
    end
  end
end
