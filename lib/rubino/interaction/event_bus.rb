# frozen_string_literal: true

module Rubino
  module Interaction
    # Simple pub/sub event bus for decoupling core logic from UI.
    # Core components emit events; UI adapters and other listeners subscribe.
    #
    # Thread-safety: subscriptions are mutated under a mutex, and `emit`
    # snapshots the listener list under the lock then invokes listeners
    # OUTSIDE the lock. This keeps concurrent `on`/`off` (e.g. a parent run's
    # `recorder.detach!` racing a background subagent thread emitting
    # SUBAGENT_COMPLETED onto the same bus — #136) from mutating the hash
    # mid-iteration, while still allowing a listener to itself emit/subscribe
    # without deadlocking.
    class EventBus
      def initialize
        @listeners = Hash.new { |h, k| h[k] = [] }
        @mutex = Mutex.new
      end

      # Subscribe to an event type with a callable or block
      def on(event_type, &block)
        @mutex.synchronize { @listeners[event_type.to_sym] << block }
      end

      # Emit an event to all registered listeners
      def emit(event_type, **payload)
        listeners = @mutex.synchronize { @listeners[event_type.to_sym].dup }
        listeners.each { |listener| listener.call(payload) }
      end

      # Remove all listeners for a given event type
      def off(event_type)
        @mutex.synchronize { @listeners.delete(event_type.to_sym) }
      end

      # Remove all listeners
      def clear!
        @mutex.synchronize { @listeners.clear }
      end

      # Returns the count of listeners for a given event type
      def listener_count(event_type)
        @mutex.synchronize { @listeners[event_type.to_sym].size }
      end
    end
  end
end
