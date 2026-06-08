# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module CronJobs
        # PATCH /v1/jobs/:id
        # Applies a partial update and resyncs the scheduler: always unschedule,
        # reschedule only when the resulting row is still enabled.
        #
        # @raise [Rubino::NotFoundError] when the cron job does not exist.
        # @raise [Rubino::ValidationError] when the body fails Schemas::UpdateCronJob.
        class UpdateOperation
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

            attrs = request.validate!(Schemas::UpdateCronJob)
            updated = @repository.update(id, attrs)
            @scheduler.unschedule(id)
            @scheduler.schedule(updated) if updated[:enabled]
            [200, Serializer.call(updated)]
          end
        end
      end
    end
  end
end
