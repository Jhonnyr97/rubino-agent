# frozen_string_literal: true

module Rubino
  module Agent
    # Manages turn and iteration budgets to prevent runaway loops.
    class IterationBudget
      def initialize(config: nil, max_tool_iterations: nil)
        @config = config || Rubino.configuration
        @max_turns = positive_int(@config.agent_max_turns)
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

      # True ONLY when offering the interactive Continue extension would actually
      # help: the SOFT iteration ceiling (@max_tool_iterations) is what's
      # exhausted, and neither non-extendable rail is the blocker (#403).
      # extend! raises only the soft ceiling, so it is impotent against the TIME
      # limit AND the max_turns OUTER rail. When either of those is what's spent,
      # extending is a no-op and re-prompting would loop forever — callers must
      # force-summarize instead. Hence extendable? is FALSE when the time limit
      # OR the max_turns outer rail is the blocker, and only TRUE when the soft
      # iteration ceiling is what's exhausted. Also false on an unbounded soft
      # cap (nothing to extend).
      def extendable?(iteration)
        within_time_limit? && within_turns_rail?(iteration) && !within_soft_iteration_limit?(iteration)
      end

      # True when the per-turn wall-clock budget (max_turn_seconds) is spent.
      # extend! cannot move this ceiling, so a time-exhausted turn must end
      # rather than re-prompt for more iterations (#403).
      def time_exhausted?
        !within_time_limit?
      end

      # Grants `by` more tool iterations so a turn that hit the cap can resume
      # the SAME turn with full context (#399, the Cline/Roo "reset the counter,
      # keep context" pattern). Only the soft iteration ceiling moves — the
      # max_turns OUTER rail and the max_turn_seconds safety-net are untouched,
      # so repeated extensions can never bypass the max_turns/clock ceiling (a
      # runaway still stops at max_turns). No-op on an unbounded (nil) cap.
      # Returns the new ceiling.
      def extend!(by)
        amount = positive_int(by)
        return @max_tool_iterations if amount.nil? || @max_tool_iterations.nil?

        @max_tool_iterations += amount
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
      # crashing the turn comparing a number with nil (#139). The full iteration
      # limit is the conjunction of the OUTER max_turns rail (#414) and the SOFT
      # @max_tool_iterations ceiling — even after extend! lifts the soft ceiling,
      # the iteration count may never exceed max_turns, so a runaway that keeps
      # extending still terminates at the hard outer bound.
      def within_iteration_limit?(iteration)
        within_turns_rail?(iteration) && within_soft_iteration_limit?(iteration)
      end

      # The OUTER max_turns rail (#414): a hard ceiling extend! cannot move. A
      # nil max_turns means this rail is unbounded.
      def within_turns_rail?(iteration)
        @max_turns.nil? || iteration <= @max_turns
      end

      # The SOFT @max_tool_iterations ceiling: the only dimension extend! can
      # lift. A nil ceiling means it is unbounded (nothing to extend).
      def within_soft_iteration_limit?(iteration)
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
