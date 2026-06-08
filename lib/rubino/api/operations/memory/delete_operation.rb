# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Memory
        # DELETE /v1/memory/:id
        # Forgets one fact by id (id-prefix match, mirroring the CLI).
        #
        # @return [[Integer, Hash]] 204 No Content.
        # @raise [Rubino::NotFoundError] when no fact matches the id.
        class DeleteOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate backend for tests.
          def initialize(backend: nil)
            @backend = backend || ::Rubino::Memory::Backends.build
          end

          def call(request)
            id = request.params.fetch("id")
            raise NotFoundError.new("memory", id) unless @backend.delete(id)

            Responses.no_content
          end
        end
      end
    end
  end
end
