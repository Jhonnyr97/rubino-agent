# frozen_string_literal: true

module Rubino
  module Security
    # Detects when the agent enters a doom loop - repeatedly calling
    # the same tool with identical arguments without progress.
    #
    # Two dimensions, both config-driven (Hermes tool_guardrails alignment,
    # #414):
    #   - threshold: how many identical consecutive calls trip detection
    #     (default 5; Hermes grades 5-8). The old default was 3, which hard-
    #     denied a legitimate 3rd retry of an idempotent read.
    #   - hard_stop: when true, a tripped detector means BLOCK (the policy
    #     returns :deny). When false (the default) it WARNS but allows — the
    #     policy surfaces a one-time warning to the model and lets the call run.
    class DoomLoopDetector
      DEFAULT_THRESHOLD = 5

      attr_reader :threshold

      def initialize(threshold: DEFAULT_THRESHOLD, hard_stop: false)
        @threshold = threshold
        @hard_stop = hard_stop
        @history = []
      end

      # True when the detector is configured to BLOCK on detection (vs. warn).
      def hard_stop?
        @hard_stop == true
      end

      # Records a tool call and returns true if a doom loop is detected
      # (the last `threshold` calls are identical). Detection is independent
      # of hard_stop — the caller decides whether a hit blocks or only warns.
      def record(tool_name:, arguments:)
        signature = generate_signature(tool_name, arguments)
        @history << signature

        # Check if the last N calls are identical
        if @history.size >= @threshold
          recent = @history.last(@threshold)
          return true if recent.uniq.size == 1
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
