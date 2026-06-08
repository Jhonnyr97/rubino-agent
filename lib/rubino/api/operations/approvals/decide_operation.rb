# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Approvals
        # POST /v1/runs/:run_id/approvals/:approval_id
        # Resolves a pending approval gate on a paused run by posting the
        # operator's decision through the in-process GateRegistry.
        #
        # @raise [Rubino::NotFoundError] when the run does not exist.
        # @raise [Rubino::ValidationError] when the body fails Schemas::DecideApproval.
        # @raise [Rubino::ConflictError] when the run has no pending gate (already decided or never opened).
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
            approval_id = request.params.fetch("approval_id")

            raise NotFoundError.new("run", run_id) unless @repository.find(run_id)

            attrs = request.validate!(Schemas::DecideApproval)
            gate = @registry.fetch(run_id)
            raise ConflictError, "no pending decisions for run #{run_id}" if gate.nil?

            # Wrong-run (or replayed) approval_id: the gate never issued it,
            # so refuse — never let an arbitrary id unblock an unrelated await.
            # Duplicate posts return the originally-resolved decision so
            # retries are idempotent (no double-unblock of the run loop).
            status = gate.decide(approval_id, attrs[:decision])
            raise NotFoundError.new("approval", approval_id) if status == :unknown

            resolved = status == :duplicate ? gate.decision_for(approval_id) : attrs[:decision]
            [200, { approval_id: approval_id, decision: resolved }]
          end
        end
      end
    end
  end
end
