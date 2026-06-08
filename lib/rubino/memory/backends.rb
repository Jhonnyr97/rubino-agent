# frozen_string_literal: true

module Rubino
  module Memory
    # Registry of pluggable memory backends, mirroring Tools::Registry: a
    # name => class map with register/build. The active backend is selected by
    # the `memory.backend` config key (default "sqlite" — the tiny-Zep FTS5/
    # graph-lite backend). DEFAULT_NAME below is the registry fallback used only
    # when the configured name is blank/unknown.
    module Backends
      @registry = {}

      class << self
        # Registers a backend class under its #backend_name.
        def register(klass)
          @registry[klass.backend_name.to_s] = klass
        end

        # All registered backend names.
        def names
          @registry.keys
        end

        def registered?(name)
          @registry.key?(name.to_s)
        end

        def fetch(name)
          @registry[name.to_s]
        end

        # Builds the configured backend instance. Falls back to the default
        # backend when `memory.backend` is unset or names an unknown backend,
        # so a stale config never breaks the interaction.
        def build(config: nil)
          cfg = config || Rubino.configuration
          name = cfg.dig("memory", "backend").to_s
          klass = @registry[name] || @registry[DEFAULT_NAME]
          raise Error, "no memory backend registered (looked for #{name.inspect})" unless klass

          klass.new(config: cfg)
        end

        # For tests.
        def reset!
          @registry = {}
        end
      end

      DEFAULT_NAME = "default"
    end
  end
end
