# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module CronJobs
        # POST /v1/jobs
        # Creates a cron job row and registers it with the in-process scheduler.
        # New jobs default to deliver="local" when the client omits it.
        #
        # @return [[Integer, Hash]] 201 + serialized job.
        # @raise [Rubino::ValidationError] when the body fails Schemas::CreateCronJob
        #   or carries a cron schedule Fugit cannot parse (#164).
        class CreateOperation
          include ScheduleValidation

          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate repository and scheduler for tests.
          def initialize(repository: nil, scheduler: nil)
            @repository = repository || ::Rubino::Jobs::CronJobRepository.new
            @scheduler = scheduler || ::Rubino::Jobs::Scheduler.instance
          end

          def call(request)
            attrs = request.validate!(Schemas::CreateCronJob)
            validate_schedule!(attrs[:schedule])
            job = @repository.create(
              name: attrs[:name],
              schedule: attrs[:schedule],
              prompt: attrs[:prompt],
              skills: attrs[:skills] || [],
              model: attrs[:model],
              provider: attrs[:provider],
              deliver: attrs[:deliver] || "local"
            )
            @scheduler.schedule(job)
            [201, Serializer.call(job)]
          end
        end
      end
    end
  end
end
