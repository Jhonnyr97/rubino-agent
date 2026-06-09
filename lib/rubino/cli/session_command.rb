# frozen_string_literal: true

require "thor"

module Rubino
  module CLI
    # Subcommands for managing chat sessions
    class SessionCommand < Thor
      # Clean `tree`/help label instead of the underscored class-name default (F12).
      namespace "rubino sessions"

      def self.exit_on_failure?
        true
      end

      desc "list", "List recent sessions"
      option :limit,  type: :numeric, default: 20, desc: "Max results"
      option :status, type: :string,  desc: "Filter by status"
      option :search, type: :string,  desc: "Filter by title (substring match)"
      def list
        Rubino.ensure_database_ready!
        repo = Session::Repository.new
        # Reap sessions left "active" by a process that died without ending them
        # (hard terminal kill / SIGKILL, #11) so the list never shows a stale
        # "active" for a window that is actually gone.
        repo.reap_orphaned_active!
        sessions = repo.list(limit: options[:limit], status: options[:status],
                             search: options[:search])

        if sessions.empty?
          Rubino.ui.info("No sessions found.")
          return
        end

        rows = sessions.map do |s|
          [s[:id][0..7], s[:title] || "(untitled)", s[:status],
           s[:message_count].to_s, s[:created_at]]
        end

        Rubino.ui.table(
          headers: %w[ID Title Status Messages Created],
          rows: rows
        )
      end

      desc "show ID", "Show session details"
      def show(id)
        Rubino.ensure_database_ready!
        repo = Session::Repository.new
        session = repo.find(id)

        if session.nil?
          Rubino.ui.error("Session not found: #{id}")
          raise Thor::Error, "session not found"
        end

        Rubino.ui.info("Session: #{session[:id]}")
        Rubino.ui.info("Title: #{session[:title] || "(untitled)"}")
        Rubino.ui.info("Status: #{session[:status]}")
        Rubino.ui.info("Model: #{session[:model]}")
        Rubino.ui.info("Messages: #{session[:message_count]}")
        Rubino.ui.info("Tokens: #{session[:token_count]}")
        Rubino.ui.info("Created: #{session[:created_at]}")
        Rubino.ui.info("Updated: #{session[:updated_at]}")

        return unless session[:parent_session_id]

        Rubino.ui.info("Parent: #{session[:parent_session_id]}")
      end

      desc "delete ID", "Permanently delete a session and all its messages/events"
      option :force, type: :boolean, default: false, aliases: "-f",
                     desc: "Skip the confirmation prompt"
      def delete(id)
        Rubino.ensure_database_ready!
        repo = Session::Repository.new
        session = repo.find(id)

        if session.nil?
          Rubino.ui.error("Session not found: #{id}")
          raise Thor::Error, "session not found"
        end

        unless options[:force]
          confirmed = Rubino.ui.confirm(
            "Delete session #{session[:id][0..7]} '#{session[:title] || "(untitled)"}'? " \
            "This will also remove its messages, events, and tool calls."
          )
          unless confirmed
            Rubino.ui.info("Aborted.")
            return
          end
        end

        repo.destroy!(session[:id])
        Rubino.ui.success("Deleted session #{session[:id][0..7]}.")
      end

      desc "compact ID", "Manually trigger compaction on a session"
      def compact(id)
        Rubino.ensure_database_ready!
        repo = Session::Repository.new
        session = repo.find(id)

        if session.nil?
          Rubino.ui.error("Session not found: #{id}")
          raise Thor::Error, "session not found"
        end

        Rubino.ui.info("Compacting session #{id}...")
        compressor = Context::Compressor.new(session_id: id)
        result = compressor.compact!
        Rubino.ui.compression_finished(result)
      end
    end
  end
end
