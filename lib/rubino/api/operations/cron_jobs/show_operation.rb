# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module CronJobs
        # GET /v1/jobs/:id
        # Fetches a single cron job by id.
        #
        # @raise [Rubino::NotFoundError] when the cron job does not exist.
        class ShowOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate repository for tests.
          def initialize(repository: nil)
            @repository = repository || ::Rubino::Jobs::CronJobRepository.new
          end

          def call(request)
            id = request.params.fetch("id")
            job = @repository.find(id)
            raise NotFoundError.new("cron_job", id) unless job

            [200, Serializer.call(job)]
          end
        end
      end
    end
  end
end
