# frozen_string_literal: true

require "securerandom"
require "json"

module Rubino
  module Run
    # Repository for Run CRUD. A Run is one user-input -> assistant-response
    # cycle within a Session, exposed as a first-class resource over the HTTP
    # API and the only persistence point for cooperative cancellation.
    #
    # Status transitions are driven by the executor:
    #   queued -> running (#mark_running!)
    #          -> completed (#mark_completed!)
    #          -> failed    (#mark_failed!)
    #          -> stopped   (#mark_stopped!)
    #
    # Cooperative stop pattern:
    #   - +POST /v1/runs/:id/stop+ calls #request_stop! which flips the
    #     +stop_requested+ boolean on the row.
    #   - The run loop is expected to poll #stop_requested? between turns
    #     and bail out, then call #mark_stopped!. The flag is a hint, not
    #     a hard kill — the worker thread keeps the CPU until it observes
    #     it. In the current Executor the in-loop poll is not yet wired,
    #     so the flag is recorded and surfaced to clients but does not
    #     actually halt an in-flight run; downstream agents should add the
    #     check inside Agent::Runner.
    #
    # +last_for_session+ uses a (created_at DESC, rowid DESC) tuple to
    # disambiguate rows created in the same second.
    class Repository
      def initialize(db: nil)
        @db = db || Rubino.database.db
      end

      def create(session_id:, input_text:, attachments: [], skills: [], model: nil, provider: nil, cron_job_id: nil)
        now = Time.now.utc.iso8601
        id = SecureRandom.uuid

        @db[:runs].insert(
          id: id,
          session_id: session_id,
          status: "queued",
          input_text: input_text,
          attachments_json: JSON.generate(attachments),
          skills_json: JSON.generate(skills),
          model: model,
          provider: provider,
          cron_job_id: cron_job_id,
          stop_requested: false,
          created_at: now,
          updated_at: now
        )
        find(id)
      end

      def find(id)
        @db[:runs].where(id: id).first
      end

      def list_for_session(session_id)
        @db[:runs].where(session_id: session_id).order(:created_at).all
      end

      def last_for_session(session_id)
        @db[:runs]
          .where(session_id: session_id)
          .order(Sequel.desc(:created_at), Sequel.desc(Sequel.lit("rowid")))
          .first
      end

      def mark_running!(id)
        now = Time.now.utc.iso8601
        @db[:runs].where(id: id).update(status: "running", started_at: now, updated_at: now)
      end

      def mark_completed!(id, tokens_input: 0, tokens_output: 0)
        now = Time.now.utc.iso8601
        @db[:runs].where(id: id).update(
          status: "completed",
          finished_at: now,
          tokens_input: tokens_input,
          tokens_output: tokens_output,
          updated_at: now
        )
      end

      def mark_failed!(id, error:)
        now = Time.now.utc.iso8601
        @db[:runs].where(id: id).update(status: "failed", error: error, finished_at: now, updated_at: now)
      end

      def mark_stopped!(id)
        now = Time.now.utc.iso8601
        @db[:runs].where(id: id).update(status: "stopped", finished_at: now, updated_at: now)
      end

      # Signals a cooperative stop. The run loop must observe this on its
      # own; nothing in this class interrupts an in-flight thread.
      def request_stop!(id)
        @db[:runs].where(id: id).update(stop_requested: true, updated_at: Time.now.utc.iso8601)
      end

      def stop_requested?(id)
        @db[:runs].where(id: id).get(:stop_requested) == true
      end

      # Cascades: deletes the run's persisted events before the run row,
      # in a single transaction (FKs are not declared at the schema level).
      def destroy!(id)
        @db.transaction do
          @db[:events].where(run_id: id).delete
          @db[:runs].where(id: id).delete
        end
      end
    end
  end
end
