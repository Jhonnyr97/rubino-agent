# frozen_string_literal: true

module Rubino
  module Context
    # Splits messages into head (protected), middle (compressible), tail (protected).
    class MessageBoundary
      def initialize(messages:, config: nil)
        @messages = messages
        @config = config || Rubino.configuration
        @protect_first = @config.compression_protect_first_n
        @protect_last = @config.compression_protect_last_n
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

      # Returns true if there are enough messages to have a middle section
      def has_compressible_middle?
        !middle.empty?
      end
    end
  end
end
