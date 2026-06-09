# frozen_string_literal: true

module Rubino
  module Agent
    # Manages turn and iteration budgets to prevent runaway loops.
    class IterationBudget
      def initialize(config: nil, max_tool_iterations: nil)
        @config = config || Rubino.configuration
        @max_turns = @config.agent_max_turns
        # An explicit override (the CLI `--max-turns N` flag, threaded through
        # Runner → Lifecycle) wins over the config default so the documented
        # control knob actually caps tool iterations (#141). A nil/blank
        # override falls back to the configured budget, unchanged.
        @max_tool_iterations = positive_int(max_tool_iterations) || @config.agent_max_tool_iterations
        @max_turn_seconds = @config.agent_max_turn_seconds
        @turn_started_at = Time.now
      end

      # Returns true if the agent can continue iterating
      def can_continue?(iteration)
        within_iteration_limit?(iteration) && within_time_limit?
      end

      private

      # Coerce an override to a positive Integer, or nil if it's absent/garbage
      # (so the config default is used). Accepts the numeric Thor option, which
      # arrives as a Float, and rejects 0/negative values as "no cap given".
      def positive_int(value)
        return nil if value.nil?

        n = Integer(value, exception: false) || Float(value, exception: false)&.to_i
        n if n && n.positive?
      end

      # A nil cap means "unbounded": never stop on that dimension rather than
      # crashing the turn comparing a number with nil (#139).
      def within_iteration_limit?(iteration)
        @max_tool_iterations.nil? || iteration <= @max_tool_iterations
      end

      def within_time_limit?
        return true if @max_turn_seconds.nil?

        elapsed = Time.now - @turn_started_at
        elapsed < @max_turn_seconds
      end
    end
  end
end
