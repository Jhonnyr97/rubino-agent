# frozen_string_literal: true

module Rubino
  module Jobs
    module Handlers
      # Extracts memories from a completed session turn.
      class ExtractMemoryJob
        def perform(payload)
          session_id = payload[:session_id]
          return unless session_id

          Memory::Backends.build.extract(session_id)
        end
      end
    end
  end
end

# Register the handler
Rubino::Jobs::Registry.register("ExtractMemoryJob", Rubino::Jobs::Handlers::ExtractMemoryJob)
