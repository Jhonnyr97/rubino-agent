# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module OAuth
        module Connections
          # GET /v1/oauth/connections
          # Lists stored OAuth connections through Serializer, which strips
          # tokens and other secret fields before they leave the API.
          class ListOperation
            def self.call(request)
              new.call(request)
            end

            # Accepts an alternate connection repository for tests.
            def initialize(repository: nil)
              @repository = repository
            end

            def call(_request)
              connections = repository.list.map { |c| Serializer.call(c) }
              [200, connections]
            end

            private

            def repository
              @repository ||= ::Rubino::OAuth::ConnectionRepository.new
            end
          end
        end
      end
    end
  end
end
