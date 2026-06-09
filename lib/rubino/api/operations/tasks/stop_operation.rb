# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Tasks
        # POST /v1/tasks/:id/stop
        # Cancels a running background subagent — the HTTP twin of the `task_stop`
        # tool. Flips the child Runner's CancelToken (the same mechanism the
        # top-level run stop-watcher uses), which unwinds the child loop
        # cooperatively at its next cancel checkpoint.
        #
        # Cancellation is asynchronous: this returns the entry's CURRENT snapshot,
        # so `status` may still read "running" until the worker thread reaches a
        # checkpoint and records its terminal (cancelled/failed) state. Poll
        # GET /v1/tasks/:id to observe the transition.
        #
        # @raise [Rubino::NotFoundError]   when no task has the id.
        # @raise [Rubino::ConflictError]   when the task is already finished.
        class StopOperation
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

            raise ConflictError, "task #{id} already #{entry.status} — nothing to stop" unless entry.status == :running

            entry.runner&.cancel!
            # Stop-cascade (S5a): wake any descendant parked on a blocking
            # ask_parent so the whole subtree unwinds at once.
            @registry.cancel_descendant_ask_gates(id)
            [202, Serializer.detail(entry)]
          end
        end
      end
    end
  end
end
