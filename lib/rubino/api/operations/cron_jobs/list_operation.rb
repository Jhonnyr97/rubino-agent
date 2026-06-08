# frozen_string_literal: true

require "json"

module Rubino
  module API
    module Operations
      module CronJobs
        # GET /v1/jobs
        # Lists cron jobs. Disabled jobs are included by default; pass
        # ?include_disabled=false to hide them.
        class ListOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate repository for tests.
          def initialize(repository: nil)
            @repository = repository || ::Rubino::Jobs::CronJobRepository.new
          end

          def call(request)
            include_disabled = request.query["include_disabled"] != "false"
            jobs = @repository.list(include_disabled: include_disabled).map { |j| Serializer.call(j) }
            [200, jobs]
          end
        end

        # Shared serializer used by every CronJobs operation so the wire shape
        # (and the JSON-decoded skills array) stays consistent.
        module Serializer
          module_function

          def call(job)
            {
              id: job[:id],
              name: job[:name],
              schedule: job[:schedule],
              prompt: job[:prompt],
              skills: job[:skills_json] ? JSON.parse(job[:skills_json]) : [],
              model: job[:model],
              provider: job[:provider],
              deliver: job[:deliver],
              enabled: job[:enabled] == true,
              last_run_at: job[:last_run_at],
              last_run_id: job[:last_run_id],
              created_at: job[:created_at],
              updated_at: job[:updated_at]
            }
          end
        end
      end
    end
  end
end
