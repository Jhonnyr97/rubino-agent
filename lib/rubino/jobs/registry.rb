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

        # Returns the handler class for a job type. Job types name classes
        # under Jobs::Handlers, so an unregistered type is resolved straight
        # from that namespace (triggering the Zeitwerk autoload) and cached.
        # This makes lookup independent of load order: a handler can never be
        # "unregistered" at run time just because nothing happened to touch
        # its constant before the inline Runner executed at enqueue time (#81).
        def handler_for(type)
          @handlers[type.to_s] || resolve(type.to_s)
        end

        # Returns all registered job types
        def registered_types
          @handlers.keys
        end

        # Clears all registrations (useful for testing)
        def reset!
          @handlers = {}
        end

        private

        def resolve(type)
          @handlers[type] = Handlers.const_get(type, false)
        rescue NameError
          nil
        end
      end
    end
  end
end
