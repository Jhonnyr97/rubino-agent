# frozen_string_literal: true

module Rubino
  module Jobs
    module Handlers
      # Extracts memories from a completed session turn.
      class ExtractMemoryJob
        def perform(payload)
          session_id = payload[:session_id]
          return unless session_id

          confirm(Memory::Backends.build.extract(session_id))
        end

        private

        # Deterministic save confirmation (#87): the agent's "I'll remember X"
        # narration is no signal that anything landed. Echo one line from the
        # actual write path, mirroring the memory tool's
        # "✓ done · memory · Memory added (id=…)" line in chat. Best-effort — a
        # UI hiccup must never fail (and re-run) a job whose writes landed.
        def confirm(stored)
          facts = Array(stored).compact
          return if facts.empty?

          ids = facts.map { |f| f[:id].to_s[0, 8] }.join(", ")
          Rubino.ui.note("✓ saved to memory · #{facts.size} fact#{"s" if facts.size != 1} (#{ids})")
        rescue StandardError
          nil
        end
      end
    end
  end
end

# Register the handler
Rubino::Jobs::Registry.register("ExtractMemoryJob", Rubino::Jobs::Handlers::ExtractMemoryJob)
