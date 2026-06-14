# frozen_string_literal: true

module Rubino
  module Output
    # Collects the per-turn telemetry the machine-readable headless output needs
    # (`rubino prompt --output-format json|stream-json`) by subscribing to the
    # existing process event bus — the SAME MODEL_CALL_FINISHED event the CLI
    # status row, the SSE server and metrics already consume. Nothing new is
    # threaded through the agent loop or the Runner's return value; the loop
    # simply emits a richer MODEL_CALL_FINISHED payload (input/output tokens +
    # stop_reason) and this recorder aggregates it off the bus.
    #
    # The per-step content blocks for stream-json are NOT reconstructed from
    # (lossy, truncated) tool events — they're read back from the persisted
    # session messages by ResultSerializer, which already hold the full
    # assistant(tool_use) / tool(result) structure with correct call-id pairing.
    #
    # Captured here:
    #   num_turns   — count of completed model calls (MODEL_CALL_FINISHED), the
    #                 same notion Claude Code reports.
    #   usage       — summed input/output tokens across every model call in the
    #                 turn. cache_* tokens are surfaced when (and only when) the
    #                 provider reports them; MiniMax does not, so they stay 0.
    #   stop_reason — the LAST model call's normalized finish reason, mapped to
    #                 the Claude-Code exit_reason vocabulary by the serializer.
    #
    # Attach before the run, detach in an ensure. A recorder is single-run.
    class TurnRecorder
      attr_reader :num_turns, :input_tokens, :output_tokens,
                  :cache_creation_input_tokens, :cache_read_input_tokens,
                  :stop_reason, :model_id

      def initialize(event_bus: Rubino.event_bus)
        @event_bus    = event_bus
        @num_turns    = 0
        @input_tokens = 0
        @output_tokens = 0
        @cache_creation_input_tokens = 0
        @cache_read_input_tokens     = 0
        @stop_reason = nil
        @model_id    = nil
        @attached    = false
      end

      # Subscribes to the bus. Idempotent.
      def attach!
        return self if @attached

        @attached = true
        @event_bus.on(Interaction::Events::MODEL_CALL_FINISHED) { |p| record_model_call(p) }
        self
      end

      # Drops THIS recorder's contribution. The bus has no per-listener removal,
      # so we flip the flag and the closure becomes an inert no-op — it only ever
      # mutates this object, never anything global.
      def detach!
        @attached = false
        self
      end

      private

      def record_model_call(payload)
        return unless @attached

        @num_turns += 1
        @input_tokens  += payload[:input_tokens].to_i
        @output_tokens += payload[:output_tokens].to_i
        @cache_creation_input_tokens += payload[:cache_creation_input_tokens].to_i
        @cache_read_input_tokens     += payload[:cache_read_input_tokens].to_i
        @stop_reason = payload[:stop_reason] unless payload[:stop_reason].nil?
        @model_id = payload[:model_id] unless payload[:model_id].nil?
      end
    end
  end
end
