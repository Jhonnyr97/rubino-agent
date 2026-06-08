# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Clarifications
        # POST /v1/runs/:run_id/clarifications/:clarify_id
        # Delivers the user's response to a clarification gate that paused the run,
        # using the same in-process GateRegistry as approvals.
        #
        # @raise [Rubino::NotFoundError] when the run does not exist.
        # @raise [Rubino::ValidationError] when the body fails Schemas::DecideClarification.
        # @raise [Rubino::ConflictError] when the run has no pending gate.
        class DecideOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate run repository and gate registry for tests.
          def initialize(repository: nil, registry: nil)
            @repository = repository || ::Rubino::Run::Repository.new
            @registry = registry || ::Rubino::Run::GateRegistry
          end

          def call(request)
            run_id = request.params.fetch("run_id")
            clarify_id = request.params.fetch("clarify_id")

            raise NotFoundError.new("run", run_id) unless @repository.find(run_id)

            attrs = request.validate!(Schemas::DecideClarification)
            gate = @registry.fetch(run_id)
            raise ConflictError, "no pending decisions for run #{run_id}" if gate.nil?

            status = gate.decide(clarify_id, attrs[:response])
            raise NotFoundError.new("clarification", clarify_id) if status == :unknown

            [200, { clarify_id: clarify_id, accepted: true }]
          end
        end
      end
    end
  end
end
