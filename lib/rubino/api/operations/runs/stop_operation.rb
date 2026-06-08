# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Runs
        # POST /v1/runs/:id/stop
        # Cooperative stop: flags the run for cancellation; the executor checks
        # between turns and exits cleanly. Returns 200 immediately — the run may
        # still take a turn to wind down.
        #
        # @raise [Rubino::NotFoundError] when the run does not exist.
        class StopOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate repository for tests.
          def initialize(repository: nil)
            @repository = repository || ::Rubino::Run::Repository.new
          end

          def call(request)
            id = request.params.fetch("id")
            raise NotFoundError.new("run", id) unless @repository.find(id)

            @repository.request_stop!(id)
            [200, { id: id, status: "stop_requested" }]
          end
        end
      end
    end
  end
end
