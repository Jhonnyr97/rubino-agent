# frozen_string_literal: true

require "securerandom"
require "json"

module Rubino
  module Run
    # Persists per-run events for SSE replay (Last-Event-ID) and audit.
    #
    # +seq+ is monotonic per +session_id+ (computed under a transaction as
    # +max(seq) + 1+) so a single Session can stream across multiple Runs
    # without seq collisions; SSE handlers send +seq+ as the event id and
    # clients resume with +after_seq+.
    #
    # Reads order primarily by +seq+; +#for_run+ inherits that ordering.
    # When two inserts land in the same wall-clock second, the
    # +(created_at, rowid)+ tuple is the implicit tiebreaker for any
    # consumer scanning by timestamp (Repository#last_for_session uses
    # the same trick).
    class EventStore
      def initialize(db: nil)
        @db = db || Rubino.database.db
      end

      def append(session_id:, run_id:, type:, payload:)
        @db.transaction do
          next_seq = (@db[:events].where(session_id: session_id).max(:seq) || 0) + 1
          row = {
            id: SecureRandom.uuid,
            session_id: session_id,
            run_id: run_id,
            type: type.to_s,
            payload_json: JSON.generate(scrub_for_json(payload)),
            seq: next_seq,
            created_at: Time.now.utc.iso8601
          }
          @db[:events].insert(row)
          row
        end
      end

      # Recursively replaces invalid UTF-8 bytes so JSON.generate never raises
      # JSON::GeneratorError on the event boundary. A tool that returns binary
      # data (e.g. ReadTool on a misdetected PDF) would otherwise blow up here,
      # propagate out of emit_finished, and kill the entire run — the model
      # would never receive a tool error result and couldn't recover.
      def scrub_for_json(value)
        case value
        when String
          if value.encoding == Encoding::UTF_8
            value.valid_encoding? ? value : value.scrub("?")
          else
            value.dup.force_encoding(Encoding::UTF_8).scrub("?")
          end
        when Hash  then value.transform_values { |v| scrub_for_json(v) }
        when Array then value.map { |v| scrub_for_json(v) }
        else            value
        end
      end

      # @param after_seq [Integer, nil] when given, returns only events with
      #   +seq > after_seq+ (used to honour SSE Last-Event-ID on reconnect).
      def for_run(run_id, after_seq: nil)
        ds = @db[:events].where(run_id: run_id).order(:seq)
        ds = ds.where { seq > after_seq } if after_seq
        ds.all
      end

      def last_seq_for_session(session_id)
        @db[:events].where(session_id: session_id).max(:seq) || 0
      end
    end
  end
end
