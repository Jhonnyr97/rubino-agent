# frozen_string_literal: true

module Rubino
  module Context
    # Splits messages into head (protected), middle (compressible), tail (protected).
    class MessageBoundary
      def initialize(messages:, config: nil)
        @messages = messages
        @config = config || Rubino.configuration
        @protect_first = @config.dig("compression", "protect_first_n")
        # Anti-task-loss (#415c, Hermes _ensure_last_user_message_in_tail):
        # guarantee the most recent user message lands in the protected tail.
        # If it falls in the compressed middle, SUMMARY_PREFIX tells the next
        # model to ignore it (reference-only) and the user's latest request
        # silently vanishes — the agent stalls or re-does old work
        # (#10896 class). Grow the protected-last window backward to cover it.
        @protect_last = [@config.dig("compression", "protect_last_n"), tail_to_last_user].max
      end

      # Returns the protected head messages (system prompt + first N)
      def head
        @messages.first(@protect_first)
      end

      # Returns the compressible middle messages
      def middle
        return [] if @messages.size <= (@protect_first + @protect_last)

        @messages[@protect_first...-@protect_last]
      end

      # Returns the protected tail messages (recent context)
      def tail
        return [] if @messages.size <= @protect_last

        @messages.last(@protect_last)
      end

      private

      # How many trailing messages must be protected to keep the most recent
      # user message inside the tail. Returns 0 when the last user message is
      # already within compression_protect_last_n, or when there is no user
      # message outside the protected head. Never grows past the head so a
      # middle always remains compressible.
      def tail_to_last_user
        last_user = @messages.rindex { |m| role_of(m) == "user" }
        return 0 if last_user.nil? || last_user < @protect_first

        from_end = @messages.size - last_user
        # Cap so head + tail never swallow the whole transcript.
        [from_end, @messages.size - @protect_first - 1].min
      end

      def role_of(msg)
        msg.respond_to?(:role) ? msg.role : msg[:role]
      end
    end
  end
end
