# frozen_string_literal: true

require "fugit"

module Rubino
  module API
    module Operations
      module CronJobs
        # Pre-flight cron validation shared by Create/Update (#164). A schedule
        # Fugit cannot parse must be rejected BEFORE the row is persisted: a
        # committed bad row used to 500 the request AND poison the next boot
        # (Scheduler#load_all! raised on it and the server never bound).
        module ScheduleValidation
          private

          def validate_schedule!(schedule)
            return if schedule.nil? || Fugit.parse_cron(schedule)

            # Same envelope shape as Request#validate! so clients see one
            # canonical 422 format: error.details.errors.<field> => [messages].
            raise ValidationError.new(
              "invalid request body",
              details: { errors: { schedule: ["is not a valid cron expression"] } }
            )
          end
        end
      end
    end
  end
end
