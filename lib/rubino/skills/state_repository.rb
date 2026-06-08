# frozen_string_literal: true

module Rubino
  module Skills
    # Persists per-skill enable/disable flags in the `skill_states` table.
    #
    # Default-enabled semantics: a skill with no row is treated as enabled,
    # so #enabled? returns true for unknown names. Only an explicit #set with
    # `enabled: false` disables a skill, and the choice survives restarts.
    #
    # Writes go through Sequel's `insert_conflict(target: :name)` which maps
    # to SQLite's `INSERT ... ON CONFLICT(name) DO UPDATE` (UPSERT).
    class StateRepository
      def initialize(db: nil)
        @db = db || Rubino.database.db
      end

      def enabled?(name)
        row = @db[:skill_states].where(name: name.to_s).first
        return true if row.nil?

        row[:enabled] == true
      end

      def set(name, enabled:)
        now = Time.now.utc.iso8601
        @db[:skill_states]
          .insert_conflict(target: :name, update: { enabled: enabled, updated_at: now })
          .insert(name: name.to_s, enabled: enabled, updated_at: now)
      end

      def all
        @db[:skill_states].all.to_h { |row| [row[:name], row[:enabled] == true] }
      end
    end
  end
end
