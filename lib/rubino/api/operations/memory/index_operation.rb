# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Memory
        # GET /v1/memory
        # Lists stored facts from the active memory backend, newest first.
        #
        # `?q=` filters to facts whose content matches the query (case-insensitive
        # substring). The match is applied at the API layer over the backend's
        # admin #list so it works identically for every backend — the backends'
        # own #retrieve is session/turn-relevance scoped and char-budget capped,
        # which is the wrong shape for a flat admin listing.
        #
        # `?limit=` / `?offset=` paginate the (optionally filtered) result.
        class IndexOperation
          DEFAULT_LIMIT = 50
          MAX_LIMIT     = 200
          # Window pulled from the backend before filter+paginate. Generous
          # enough to page through a normal store; the backend keeps its own
          # newest-first ordering.
          WINDOW        = 1000

          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate backend for tests.
          def initialize(backend: nil)
            @backend = backend || ::Rubino::Memory::Backends.build
          end

          def call(request)
            limit  = clamp(request.query["limit"], DEFAULT_LIMIT, MAX_LIMIT)
            offset = [request.query["offset"].to_i, 0].max
            q      = request.query["q"].to_s.strip

            rows = @backend.list(limit: WINDOW)
            rows = filter(rows, q) unless q.empty?

            page = rows.slice(offset, limit) || []
            [200, { memory: page.map { |row| Serializer.call(row) } }]
          end

          private

          def filter(rows, q)
            needle = q.downcase
            rows.select { |row| row[:content].to_s.downcase.include?(needle) }
          end

          def clamp(raw, default, max)
            n = raw.to_i
            return default if n <= 0

            [n, max].min
          end
        end

        # Shared serializer for the memory surface. Backends differ slightly in
        # the rows they return (the sqlite backend omits :updated_at), so every
        # field is read defensively and absent ones serialize to null.
        module Serializer
          module_function

          def call(row)
            {
              id: row[:id],
              kind: row[:kind],
              content: row[:content],
              created_at: row[:created_at],
              updated_at: row[:updated_at]
            }
          end
        end
      end
    end
  end
end
