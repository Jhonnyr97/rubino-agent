# frozen_string_literal: true

module Rubino
  module Security
    # Detects when the agent enters a doom loop - repeatedly calling
    # the same tool with identical arguments without progress.
    class DoomLoopDetector
      DEFAULT_THRESHOLD = 3

      def initialize(threshold: DEFAULT_THRESHOLD)
        @threshold = threshold
        @history = []
      end

      # Records a tool call and returns true if a doom loop is detected
      def record(tool_name:, arguments:)
        signature = generate_signature(tool_name, arguments)
        @history << signature

        # Check if the last N calls are identical
        if @history.size >= @threshold
          recent = @history.last(@threshold)
          if recent.uniq.size == 1
            return true
          end
        end

        false
      end

      # Resets the detector (e.g., when user provides new input)
      def reset!
        @history.clear
      end

      private

      def generate_signature(tool_name, arguments)
        # Create a deterministic signature from tool name + sorted arguments
        args_str = arguments.sort_by { |k, _| k.to_s }.map { |k, v| "#{k}=#{v}" }.join("&")
        "#{tool_name}:#{args_str}"
      end
    end
  end
end
