# frozen_string_literal: true

module Rubino
  module Memory
    # Registry of pluggable memory backends, mirroring Tools::Registry: a
    # name => class map with register/build. The active backend is selected by
    # the `memory.backend` config key (default "sqlite" — the FTS5/
    # graph-lite SQLite backend). DEFAULT_NAME below is the registry fallback used only
    # when the configured name is BLANK/unset. An explicitly-set UNKNOWN name is
    # a misconfiguration (a typo silently degrading memory) → rejected.
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

        # Builds the configured backend instance. A BLANK/unset `memory.backend`
        # falls back to the default backend (so a fresh config just works); an
        # explicitly-set name that names NO registered backend is a typo that
        # would otherwise silently degrade to the default — reject it with a
        # clear error listing the known backends instead.
        def build(config: nil)
          cfg = config || Rubino.configuration
          name = cfg.dig("memory", "backend").to_s.strip
          klass = name.empty? ? @registry[DEFAULT_NAME] : @registry[name]

          unless klass
            raise Error, unknown_backend_message(name) unless name.empty?

            raise Error, "no memory backend registered (looked for #{DEFAULT_NAME.inspect})"
          end

          klass.new(config: cfg)
        end

        # A clear, actionable rejection for an unknown `memory.backend` name,
        # listing the registered backends so the user can fix the typo.
        def unknown_backend_message(name)
          known = names.sort.join(", ")
          "unknown memory backend #{name.inspect}: set memory.backend to one of " \
            "[#{known}] (or leave it unset for the default)."
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
