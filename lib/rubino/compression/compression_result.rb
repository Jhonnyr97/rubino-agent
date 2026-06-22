# frozen_string_literal: true

module Rubino
  # Deterministic, reversible compression of tool-read results. When the agent
  # reads a LARGE code file just to understand its shape (a WHOLE-file read, no
  # offset/limit), we hand back a SKELETON — requires, signatures, constants and
  # small bodies kept verbatim; large method bodies elided behind an ACTIONABLE
  # pointer that is itself a targeted read (`read <path> offset=.. limit=..`).
  #
  # The whole safety story is the DRILL-IN INVARIANT: exploration is cheap
  # (skeleton), but the moment the model needs an exact body (e.g. to edit it) it
  # issues the pointer's targeted read and gets the ORIGINAL bytes back verbatim,
  # so the edit tool's exact-string match still works. Compression is lossy on
  # the WHOLE-file view ONLY; every byte is one targeted read away.
  module Compression
    # Immutable result of one compression attempt. `applied?` is the single gate
    # the caller checks: when false, `text` is meaningless (use the original) and
    # `saved_tokens_est` is zeroed. When true, `text` is the skeleton and
    # `saved_tokens_est` is the estimated saving. `strategy` is :skeleton (or the
    # per-type tag) when applied, otherwise the no-op REASON (:not_full_file/
    # :not_code/:too_small/:parse_error/:insufficient_saving) for measurement events.
    CompressionResult = Data.define(
      :text, :saved_tokens_est, :strategy, :applied
    ) do
      def applied?
        applied
      end

      # The no-op result: nothing was compressed, the caller sends the original.
      def self.noop(strategy:)
        new(text: nil, saved_tokens_est: 0, strategy: strategy, applied: false)
      end
    end
  end
end
