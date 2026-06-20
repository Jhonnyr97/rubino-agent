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
    # the byte/token fields are zeroed. When true, `text` is the skeleton and the
    # numbers describe the saving. `strategy` is :skeleton when applied, otherwise
    # the no-op REASON (:not_full_file/:not_code/:too_small/:parse_error/
    # :insufficient_saving) for the measurement events.
    CompressionResult = Data.define(
      :text, :original_bytes, :compressed_bytes,
      :saved_tokens_est, :ratio, :strategy, :applied
    ) do
      def applied?
        applied
      end

      # The no-op result: nothing was compressed, the caller sends the original.
      def self.noop(strategy:, original_bytes: 0)
        new(text: nil, original_bytes: original_bytes, compressed_bytes: original_bytes,
            saved_tokens_est: 0, ratio: 0.0, strategy: strategy, applied: false)
      end
    end
  end
end
