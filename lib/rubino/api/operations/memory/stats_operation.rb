# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Memory
        # GET /v1/memory/stats
        # Returns the active backend's name and total fact count — the data the
        # CLI /status line and the web dashboard's memory card need without
        # paging the whole store.
        class StatsOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate backend for tests.
          def initialize(backend: nil)
            @backend = backend || ::Rubino::Memory::Backends.build
          end

          def call(_request)
            [200, { backend: @backend.class.backend_name, count: @backend.count }]
          end
        end
      end
    end
  end
end
