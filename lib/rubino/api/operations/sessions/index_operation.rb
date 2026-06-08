# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Sessions
        # GET /v1/sessions
        # Lists recent sessions. When `?q=` is present, switches to FTS5 mode
        # and returns the sessions whose messages match the query, ordered by
        # the most-recent matching message. Reusing the same route keeps the
        # client surface small — clients only need to learn one endpoint.
        class IndexOperation
          DEFAULT_LIMIT = 20
          MAX_LIMIT     = 100

          def self.call(request)
            new.call(request)
          end

          # Accepts alternate dependencies for tests.
          def initialize(repository: nil, message_store: nil)
            @repository = repository || ::Rubino::Session::Repository.new
            @message_store = message_store || ::Rubino::Session::Store.new
          end

          def call(request)
            limit = clamp_limit(request.query["limit"])
            q = request.query["q"].to_s.strip

            sessions = q.empty? ? list_recent(limit) : search(q, limit)
            [200, { sessions: sessions.map { |s| serialize(s) } }]
          end

          private

          def list_recent(limit)
            @repository.list(limit: limit)
          end

          # Search mode: group FTS5 hits by session, ordered by the latest hit.
          # The store gives us per-message rows; we collapse them down to one
          # entry per session and look up the session row to keep the wire
          # shape identical to list mode.
          def search(q, limit)
            hits = @message_store.search(query: q, limit: MAX_LIMIT)
            ordered_ids = []
            seen = {}
            hits.each do |hit|
              sid = hit[:session_id]
              next if seen[sid]

              seen[sid] = true
              ordered_ids << sid
              break if ordered_ids.size >= limit
            end

            ordered_ids.filter_map { |id| @repository.find(id) }
          end

          def clamp_limit(raw)
            n = raw.to_i
            return DEFAULT_LIMIT if n <= 0

            [n, MAX_LIMIT].min
          end

          def serialize(session)
            {
              id: session[:id],
              title: session[:title],
              status: session[:status],
              created_at: session[:created_at],
              updated_at: session[:updated_at],
              message_count: session[:message_count],
              token_count: session[:token_count]
            }
          end
        end
      end
    end
  end
end
