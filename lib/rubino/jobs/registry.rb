# frozen_string_literal: true

module Rubino
  module Jobs
    # Registry that maps job type strings to handler classes.
    class Registry
      @handlers = {}

      class << self
        # Registers a handler class for a job type
        def register(type, handler_class)
          @handlers[type.to_s] = handler_class
        end

        # Returns the handler class for a job type
        def handler_for(type)
          @handlers[type.to_s]
        end

        # Returns all registered job types
        def registered_types
          @handlers.keys
        end

        # Clears all registrations (useful for testing)
        def reset!
          @handlers = {}
        end
      end
    end
  end
end
