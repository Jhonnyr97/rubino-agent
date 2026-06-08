# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module CronJobs
        # POST /v1/jobs/:id/resume
        # Flips enabled=true on the cron job and (re)registers its tick. Idempotent.
        #
        # @raise [Rubino::NotFoundError] when the cron job does not exist.
        class ResumeOperation
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

            updated = @repository.set_enabled(id, enabled: true)
            @scheduler.schedule(updated)
            [200, Serializer.call(updated)]
          end
        end
      end
    end
  end
end
