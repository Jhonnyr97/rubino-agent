# frozen_string_literal: true

module Rubino
  module Jobs
    module Handlers
      # Triggers context compaction for a session that exceeded threshold.
      class CompactSessionJob
        def perform(payload)
          session_id = payload[:session_id]
          return unless session_id

          compressor = Context::Compressor.new(session_id: session_id)
          compressor.compact!
        end
      end
    end
  end
end

# Register the handler
Rubino::Jobs::Registry.register("CompactSessionJob", Rubino::Jobs::Handlers::CompactSessionJob)
