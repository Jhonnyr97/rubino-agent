# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module CronJobs
        # DELETE /v1/jobs/:id
        # Unschedules the cron job from the in-process scheduler before deleting
        # the row, so no stray ticks fire post-delete.
        #
        # @return [[Integer, Hash]] 204 No Content.
        # @raise [Rubino::NotFoundError] when the cron job does not exist.
        class DeleteOperation
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

            @scheduler.unschedule(id)
            @repository.destroy!(id)
            Responses.no_content
          end
        end
      end
    end
  end
end
