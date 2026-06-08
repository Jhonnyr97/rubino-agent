# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Tasks
        # GET /v1/tasks
        # Lists background subagents started by the `task` tool, newest first.
        # Each row is the summary shape (no full result body — see the show
        # endpoint for that). The registry is process-local and not persisted,
        # so this reflects only the current server process's children.
        class IndexOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate registry for tests.
          def initialize(registry: nil)
            @registry = registry || ::Rubino::Tools::BackgroundTasks.instance
          end

          def call(_request)
            tasks = @registry.list.map { |entry| Serializer.summary(entry) }
            [200, { tasks: tasks }]
          end
        end
      end
    end
  end
end
