# frozen_string_literal: true

module Rubino
  # HTTP-boundary error hierarchy. Each class maps to a single HTTP status
  # used by the API layer to translate exceptions to responses.
  #
  #   Rubino::Error                       — base class (defined in lib/rubino.rb)
  #     NotFoundError(resource, id)          — 404
  #     ValidationError(message, details:)   — 422
  #     UnauthorizedError(message)           — 401
  #     ConflictError(message)               — 409
  #     UpstreamError(message, service:)     — 502
  #
  # All message-first classes accept `raise Class, "msg"` (Ruby's idiomatic
  # form) without losing data. NotFoundError keeps its (resource, id) shape
  # because the message format depends on both values; always use
  # +raise NotFoundError.new("session", id)+, not +raise NotFoundError, "..."+.
  #
  # Domain errors (ConfigurationError, DatabaseError, SessionError, ToolError,
  # CompactionError, JobError) also subclass Error and live in lib/rubino.rb.

  # Resource not found. Maps to 404.
  #
  # @param resource [String, Symbol] resource type (e.g. "Session", :run)
  # @param id [String, nil] identifier; when nil only the resource name is shown
  #
  # Footgun: `raise NotFoundError, "foo"` skips this initializer (Ruby passes
  # the string straight to StandardError#initialize), so @resource/@id stay nil.
  # Always use `raise NotFoundError.new("Session", id)` to capture them.
  class NotFoundError < Error
    def initialize(resource, id = nil)
      msg = id ? "#{resource} not found: #{id}" : "#{resource} not found"
      super(msg)
      @resource = resource
      @id = id
    end
    attr_reader :resource, :id
  end

  # Request body or params failed validation. Maps to 422.
  class ValidationError < Error
    def initialize(message = "validation failed", details: {})
      super(message)
      @details = details
    end
    attr_reader :details
  end

  # Missing or invalid credentials. Maps to 401.
  class UnauthorizedError < Error
    def initialize(message = "unauthorized")
      super
    end
  end

  # State conflict (duplicate, illegal transition). Maps to 409.
  class ConflictError < Error
    def initialize(message = "conflict")
      super
    end
  end

  # An in-progress LLM turn was aborted. +reason+ distinguishes a deliberate
  # user interrupt (Esc / Ctrl+C in the chat TUI — :user) from an EXTERNAL
  # teardown (SIGTERM/SIGHUP from systemd, a terminal close, or a supervisor
  # kill — :external). Both are caught by the Loop/Lifecycle so partial content
  # can still be persisted and the UI returns to a ready state cleanly, but the
  # result LABEL must not claim "interrupted by user" when no user interrupted
  # (#361b). Default stays :user with the historical message for compatibility.
  class Interrupted < Error
    attr_reader :reason

    def initialize(message = nil, reason: :user)
      @reason = reason
      super(message || default_message(reason))
    end

    private

    def default_message(reason)
      reason == :external ? "interrupted by external signal" : "interrupted by user"
    end
  end

  # Request body exceeded the configured byte cap (JSON or multipart upload).
  # Maps to 413. Details may carry +limit_bytes+ so clients can adapt.
  class PayloadTooLargeError < Error
    def initialize(message = "payload too large", details: {})
      super(message)
      @details = details
    end
    attr_reader :details
  end

  # Upstream dependency failed (LLM provider, OAuth provider). Maps to 502.
  # Message-first so +raise UpstreamError, "timeout"+ works; pass +service:+
  # to tag the failing dependency (it gets prefixed onto the message).
  class UpstreamError < Error
    def initialize(message = "upstream error", service: nil)
      super(service ? "#{service}: #{message}" : message)
      @service = service
    end
    attr_reader :service
  end

  # The LLM streaming response was cut before a clean completion: upstream closed
  # the SSE connection without a terminal signal (no finish_reason / no [DONE] /
  # null usage), leaving only a buffered partial with no tool call. Raised by the
  # Loop so a truncated turn fails honestly (run.failed) instead of being reported
  # as a successful "completed" turn carrying empty/partial output. Common trigger:
  # a provider stream idle-timeout during a long time-to-first-token on a very
  # large context. Maps to 502 (subclass of UpstreamError).
  class StreamInterruptedError < UpstreamError
    def initialize(message = "stream ended before completion", service: "llm")
      super
    end
  end

  # The model returned a degenerate turn — no text AND no tool calls — that
  # survived the Loop's in-turn retries. Mirrors the reference treating an
  # empty/invalid response as retryable-then-terminal (such a run is
  # marked `failed: True`, not `completed`). Raised by Agent::Loop so
  # the run is marked failed honestly instead of being reported as a successful
  # "completed" turn carrying empty output (the silent completed-but-empty bug,
  # observed on MiniMax-M2.7 / api.minimax.io/anthropic). Maps to 502.
  class EmptyModelResponseError < UpstreamError
    def initialize(message = "model returned an empty response (no text, no tool calls)",
                   service: "llm")
      super
    end
  end
end
