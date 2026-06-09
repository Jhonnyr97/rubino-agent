# frozen_string_literal: true

require "securerandom"
require "json"

module Rubino
  module Memory
    # Primary storage interface for persistent memories.
    # Handles CRUD operations on the memories table.
    class Store
      VALID_KINDS = %w[
        user_profile
        preference
        project_context
        technical_decision
        fact
        task_state
        tool_result
      ].freeze

      # Raised when ThreatScanner flags content destined for the store.
      # Carries the threat label so callers can branch on it without
      # parsing the human-facing message.
      class ThreatDetectedError < Rubino::Error
        attr_reader :threat

        def initialize(threat)
          @threat = threat
          super("memory threat detected: #{threat}")
        end
      end

      # Raised when adding `content` to `kind`'s group would push the
      # group's total characters past the configured budget. Group rules
      # live in Store#group_for_kind — user_profile is its own group,
      # everything else shares the general "memory" budget.
      class BudgetExceededError < Rubino::Error
        attr_reader :group, :limit, :current, :requested

        def initialize(group:, limit:, current:, requested:)
          @group     = group
          @limit     = limit
          @current   = current
          @requested = requested
          super("memory budget exceeded for #{group}: " \
                "#{current}+#{requested} > #{limit}")
        end
      end

      def initialize(db: nil, config: nil)
        @db = db || Rubino.database.db
        @config = config
      end

      # Creates a new memory entry.
      #
      # Two boundary checks run *before* the row is inserted:
      #   1. ThreatScanner — refuses prompt-injection, exfil, invisible
      #      unicode, etc. Memory persists across sessions, so a tainted
      #      write would keep biasing every future prompt.
      #   2. char-budget — refuses writes that would push the group's
      #      total past memory_char_limit / memory_user_char_limit. Lets
      #      callers (Tools::MemoryTool) surface a "delete or replace
      #      older entries first" message instead of silently truncating
      #      at read-time.
      def create(kind:, content:, source_session_id: nil, confidence: 1.0, metadata: {})
        validate_kind!(kind)
        enforce_threat_scan!(content)
        enforce_char_budget!(kind, content)

        now = Time.now.utc.iso8601
        id = SecureRandom.uuid

        @db[:memories].insert(
          id: id,
          kind: kind,
          content: content,
          source_session_id: source_session_id,
          confidence: confidence,
          metadata_json: metadata.empty? ? nil : JSON.generate(metadata),
          created_at: now,
          updated_at: now
        )

        find(id)
      end

      # Finds a memory by ID (supports prefix matching)
      def find(id)
        @db[:memories].where(Sequel.like(:id, "#{id}%")).first
      end

      # Lists memories with optional filters
      def list(kind: nil, limit: 20)
        dataset = @db[:memories].order(Sequel.desc(:created_at)).limit(limit)
        dataset = dataset.where(kind: kind) if kind
        dataset.all
      end

      # Updates a memory's content.
      #
      # Same two boundary checks as create — the replace path was a hole that
      # let an agent rewrite a benign entry with prompt-injection / exfil
      # content without going through ThreatScanner, and let a chain of
      # replaces grow a group past its char budget one byte at a time. The
      # budget check subtracts the old row's length before re-adding the new,
      # otherwise a same-size edit would be flagged as over budget when it
      # isn't.
      def update(id, content:, confidence: nil)
        existing = find(id)
        enforce_threat_scan!(content)
        enforce_char_budget_for_update!(existing, content) if existing

        attrs = { content: content, updated_at: Time.now.utc.iso8601 }
        attrs[:confidence] = confidence if confidence
        @db[:memories].where(id: id).update(attrs)
      end

      # Deletes a memory
      def delete(id)
        count = @db[:memories].where(Sequel.like(:id, "#{id}%")).delete
        count > 0
      end

      # Returns memories of a specific kind
      def by_kind(kind, limit: 50)
        @db[:memories]
          .where(kind: kind)
          .order(Sequel.desc(:confidence), Sequel.desc(:created_at))
          .limit(limit)
          .all
      end

      # Returns all memories within the character limit
      def within_limit(char_limit:)
        memories = @db[:memories]
                   .order(Sequel.desc(:confidence), Sequel.desc(:updated_at))
                   .all

        selected = []
        total_chars = 0

        memories.each do |m|
          break if total_chars + m[:content].length > char_limit

          selected << m
          total_chars += m[:content].length
        end

        selected
      end

      # Returns the total count of stored memories
      def count
        @db[:memories].count
      end

      # Returns the budget group a kind belongs to:
      # - "user"   → user_profile (its own dedicated budget)
      # - "memory" → everything else (shared general-memory budget)
      def self.group_for_kind(kind)
        kind == "user_profile" ? "user" : "memory"
      end

      # Sum of content length across every row in the given group.
      def total_chars_for_group(group)
        if group == "user"
          @db[:memories].where(kind: "user_profile").sum(Sequel.function(:length, :content)).to_i
        else
          @db[:memories].exclude(kind: "user_profile").sum(Sequel.function(:length, :content)).to_i
        end
      end

      private

      def validate_kind!(kind)
        return if VALID_KINDS.include?(kind)

        raise Error, "Invalid memory kind: #{kind}. Valid: #{VALID_KINDS.join(", ")}"
      end

      def enforce_threat_scan!(content)
        threat = ThreatScanner.scan(content)
        return unless threat

        begin
          Rubino.logger.warn(event: "memory.threat_detected", threat: threat)
        rescue StandardError
          # logging must never block the refusal path
        end
        raise ThreatDetectedError.new(threat)
      end

      def enforce_char_budget!(kind, content)
        cfg = @config || Rubino.configuration
        group = self.class.group_for_kind(kind)
        limit = group == "user" ? cfg.memory_user_char_limit : cfg.memory_char_limit
        return unless limit && limit > 0

        current = total_chars_for_group(group)
        requested = content.to_s.length
        return if current + requested <= limit

        raise BudgetExceededError.new(
          group: group, limit: limit, current: current, requested: requested
        )
      end

      # Update variant: subtract the row's current content length from the
      # group total before checking the new one, so a same-size or smaller
      # edit always passes even when the group is already at the limit.
      def enforce_char_budget_for_update!(existing, new_content)
        cfg = @config || Rubino.configuration
        group = self.class.group_for_kind(existing[:kind])
        limit = group == "user" ? cfg.memory_user_char_limit : cfg.memory_char_limit
        return unless limit && limit > 0

        current = total_chars_for_group(group) - existing[:content].to_s.length
        requested = new_content.to_s.length
        return if current + requested <= limit

        raise BudgetExceededError.new(
          group: group, limit: limit, current: current, requested: requested
        )
      end
    end
  end
end
