# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Sessions
        # DELETE /v1/sessions/:id
        # Cascade-deletes the session and its messages/runs/events.
        #
        # @return [[Integer, Hash]] 204 No Content.
        # @raise [Rubino::NotFoundError] when the session does not exist.
        class DeleteOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate repository for tests.
          def initialize(repository: nil)
            @repository = repository || ::Rubino::Session::Repository.new
          end

          def call(request)
            id = request.params.fetch("id")
            raise NotFoundError.new("session", id) unless @repository.find(id)

            @repository.destroy!(id)
            Responses.no_content
          end
        end
      end
    end
  end
end
