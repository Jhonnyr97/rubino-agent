# frozen_string_literal: true

require "securerandom"
require "json"

module Rubino
  module Tools
    # Persists tool call audit records to the database.
    # Extracted from Agent::ToolExecutor to respect the separation between
    # domain execution logic and storage concerns.
    class ToolCallRepository
      # Persists a tool call record. Failures are swallowed so that a
      # database outage never causes a tool call to fail.
      def record(name:, call_id:, arguments:, result:, status:, error: nil)
        now = Time.now.utc.iso8601
        Rubino.database.db[:tool_calls].insert(
          id:          call_id || SecureRandom.uuid,
          session_id:  result.session_id,
          tool_name:   name,
          input_json:  JSON.generate(arguments),
          output:      result.output,
          status:      status,
          started_at:  now,
          finished_at: now,
          error:       error
        )
      rescue StandardError
        # Don't fail the tool call just because audit persistence failed.
        nil
      end
    end
  end
end
