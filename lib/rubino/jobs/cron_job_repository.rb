# frozen_string_literal: true

require "securerandom"
require "json"

module Rubino
  module Jobs
    # Repository for cron job definitions. Plain CRUD on the +cron_jobs+
    # table; execution is orchestrated by Jobs::Scheduler.
    #
    # The +DELIVERS+ constant documents the accepted values for the
    # +deliver+ column, but it is NOT enforced here: validation of the
    # +local+/+webhook+ enum lives in the dry-schema at the HTTP boundary
    # (see Api::Schemas). Callers that bypass the HTTP layer can insert any
    # string; Scheduler#deliver_if_needed only acts on the exact match
    # +"webhook"+, treating anything else as no-op delivery.
    class CronJobRepository
      DELIVERS = %w[local webhook].freeze

      def initialize(db: nil)
        @db = db || Rubino.database.db
      end

      def create(name:, schedule:, prompt:, skills: [], model: nil, provider: nil, deliver: "local", enabled: true)
        now = Time.now.utc.iso8601
        id = SecureRandom.uuid
        @db[:cron_jobs].insert(
          id: id, name: name, schedule: schedule, prompt: prompt,
          skills_json: JSON.generate(skills), model: model, provider: provider,
          deliver: deliver, enabled: enabled, created_at: now, updated_at: now
        )
        find(id)
      end

      def find(id)
        @db[:cron_jobs].where(id: id).first
      end

      def list(include_disabled: true)
        ds = @db[:cron_jobs].order(:name)
        ds = ds.where(enabled: true) unless include_disabled
        ds.all
      end

      # Partial update. Unknown keys are silently dropped (whitelist via slice);
      # +:skills+ accepts an Array of strings and is JSON-encoded into the
      # +skills_json+ column.
      # @return [Hash, nil] the refreshed row, or nil if the id does not exist.
      def update(id, attrs)
        return nil unless find(id)

        attrs = attrs.transform_keys(&:to_sym).slice(:name, :schedule, :prompt, :skills, :model, :provider, :deliver,
                                                     :enabled)
        attrs[:skills_json] = JSON.generate(attrs.delete(:skills) || []) if attrs.key?(:skills)
        attrs[:updated_at] = Time.now.utc.iso8601
        @db[:cron_jobs].where(id: id).update(attrs)
        find(id)
      end

      def set_enabled(id, enabled:)
        update(id, enabled: enabled)
      end

      # Stamps +last_run_at+/+last_run_id+ after Scheduler#fire creates the run.
      def record_run(id, run_id:)
        now = Time.now.utc.iso8601
        @db[:cron_jobs].where(id: id).update(last_run_at: now, last_run_id: run_id, updated_at: now)
      end

      def destroy!(id)
        @db[:cron_jobs].where(id: id).delete
      end
    end
  end
end
