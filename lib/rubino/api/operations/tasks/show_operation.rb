# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Tasks
        # GET /v1/tasks/:id
        # Full detail for one background subagent, including its complete result
        # (on success) or error (on failure).
        #
        # @raise [Rubino::NotFoundError] when no task has the id.
        class ShowOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate registry for tests.
          def initialize(registry: nil)
            @registry = registry || ::Rubino::Tools::BackgroundTasks.instance
          end

          def call(request)
            id = request.params.fetch("id")
            entry = @registry.find(id)
            raise NotFoundError.new("task", id) unless entry

            [200, Serializer.detail(entry)]
          end
        end
      end
    end
  end
end
