# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module CronJobs
        # POST /v1/jobs/:id/trigger
        # Forces an off-cycle execution of the cron job through the scheduler
        # and returns the new run/session ids.
        #
        # @return [[Integer, Hash]] 202 + { job_id, run_id, session_id }.
        # @raise [Rubino::NotFoundError] when the cron job does not exist.
        # @raise [Rubino::ConflictError] when the scheduler refuses to dispatch (returns nil).
        class TriggerOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate repository and scheduler for tests.
          def initialize(repository: nil, scheduler: nil)
            @repository = repository || ::Rubino::Jobs::CronJobRepository.new
            @scheduler = scheduler || ::Rubino::Jobs::Scheduler.instance
          end

          def call(request)
            id = request.params.fetch("id")
            raise NotFoundError.new("cron_job", id) unless @repository.find(id)

            run = @scheduler.trigger(id)
            raise ConflictError, "trigger failed" if run.nil?

            [202, { job_id: id, run_id: run[:id], session_id: run[:session_id] }]
          end
        end
      end
    end
  end
end
