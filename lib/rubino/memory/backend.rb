# frozen_string_literal: true

module Rubino
  module Memory
    # Duck-typed contract for a pluggable memory backend.
    #
    # A backend owns the WRITE path (store / replace / forget / extract), the
    # READ path the prompt assembler depends on (user_profile / project_context
    # / retrieve), and the admin surface that powers `rubino memory ...`
    # (list / find). The method set is the union of what the rest of the gem
    # already calls today — extracting this interface is a mechanical refactor,
    # not a rewrite.
    #
    # The injection-defense floor (ThreatScanner + the char-budget enforced in
    # Memory::Store) lives in the shared write path, so no backend can splice
    # tainted or over-budget content into a future system prompt. Concrete
    # backends override only what they need; the base raises NotImplementedError
    # for the operations that have no sensible default.
    class Backend
      # Backend registry key (e.g. "default"). Subclasses must override.
      def self.backend_name
        raise NotImplementedError, "#{self} must define .backend_name"
      end

      def initialize(config: nil)
        @config = config || Rubino.configuration
      end

      # Deps present + configured (no network). Backends with optional
      # dependencies override this; the default is always available.
      def available?
        true
      end

      # -- WRITE path --

      # Persist one memory entry. Returns the stored row (Hash) or raises a
      # Memory::Store::ThreatDetectedError / BudgetExceededError on refusal.
      def store(kind:, content:, source_session_id: nil, confidence: 1.0, metadata: {})
        raise NotImplementedError, "#{self.class} must implement #store"
      end

      # Replace the content of the first entry of `kind` whose content includes
      # `old_text`. Returns the matched row, or nil if nothing matched.
      def replace(kind:, old_text:, content:)
        raise NotImplementedError, "#{self.class} must implement #replace"
      end

      # Delete the first entry of `kind` whose content includes `old_text`.
      # Returns the matched row, or nil if nothing matched.
      def forget(kind:, old_text:)
        raise NotImplementedError, "#{self.class} must implement #forget"
      end

      # Mine a session's messages for durable facts and persist them.
      # Returns the list of stored entries.
      def extract(session_id)
        raise NotImplementedError, "#{self.class} must implement #extract"
      end

      # -- READ path (consumed by lifecycle#load_memory -> PromptAssembler) --

      # User-profile text (String) or nil.
      def user_profile
        raise NotImplementedError, "#{self.class} must implement #user_profile"
      end

      # Project-context text (String) or nil.
      def project_context
        raise NotImplementedError, "#{self.class} must implement #project_context"
      end

      # Memories relevant to the turn. `query` lets a relevance-aware backend
      # rank by the last user message; the default backend ignores it and
      # returns everything that fits, exactly as today. Returns an array of
      # rows ([{id:, kind:, content:, ...}]).
      def retrieve(session_id:, query: nil)
        raise NotImplementedError, "#{self.class} must implement #retrieve"
      end

      # -- admin (powers `rubino memory list/show/delete`) --

      def list(kind: nil, limit: 20)
        raise NotImplementedError, "#{self.class} must implement #list"
      end

      def find(id)
        raise NotImplementedError, "#{self.class} must implement #find"
      end

      def delete(id)
        raise NotImplementedError, "#{self.class} must implement #delete"
      end

      # Total number of stored memories. Powers the CLI /status line and the
      # web dashboard's memory card via GET /v1/memory/stats.
      def count
        raise NotImplementedError, "#{self.class} must implement #count"
      end
    end
  end
end
