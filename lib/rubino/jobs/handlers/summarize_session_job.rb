# frozen_string_literal: true

module Rubino
  module Jobs
    module Handlers
      # Generates or updates a session summary.
      class SummarizeSessionJob
        def perform(payload)
          session_id = payload[:session_id]
          return unless session_id

          builder = Context::SummaryBuilder.new(session_id: session_id)
          builder.build_and_save!
        end
      end
    end
  end
end

# Register the handler
Rubino::Jobs::Registry.register("SummarizeSessionJob", Rubino::Jobs::Handlers::SummarizeSessionJob)
