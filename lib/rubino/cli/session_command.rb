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

        # One error, one style (#20): Thor already prints the Thor::Error message
        # to stderr and exits non-zero (exit_on_failure?), so the extra styled
        # ui.error line was the same failure repeated in a second format.
        raise Thor::Error, "session not found: #{id}" if session.nil?

        self.class.render(session, ui: Rubino.ui)
      end

      # ONE session-details rendering for both surfaces (#183): the CLI verb
      # above and the in-chat `/sessions show <id>` (Commands::Executor).
      def self.render(session, ui:)
        # Title/Model are attacker-influenceable (the title is generated from
        # the conversation), and the rest are defensively sanitized too: `info`
        # does NOT neutralize escapes, so a raw `\e]0;…\a` / `\e[2J` here would
        # hijack the window title or clear the screen (CWE-150, R4-N2). Render
        # any control bytes as visible caret notation instead.
        ui.info("Session: #{safe(session[:id])}")
        ui.info("Title: #{safe(session[:title] || "(untitled)")}")
        ui.info("Status: #{safe(session[:status])}")
        ui.info("Model: #{safe(session[:model])}")
        ui.info("Messages: #{safe(session[:message_count])}")
        ui.info("Tokens: #{safe(session[:token_count])}")
        ui.info("Created: #{safe(session[:created_at])}")
        ui.info("Updated: #{safe(session[:updated_at])}")

        return unless session[:parent_session_id]

        ui.info("Parent: #{safe(session[:parent_session_id])}")
      end

      # Neutralize terminal-control bytes in untrusted stored session fields to
      # visible caret notation before the non-sanitizing `info` funnel (CWE-150).
      def self.safe(text)
        Util::Output.sanitize_terminal(text)
      end

      desc "delete ID", "Permanently delete a session and all its messages/events"
      option :force, type: :boolean, default: false, aliases: "-f",
                     desc: "Skip the confirmation prompt"
      def delete(id)
        Rubino.ensure_database_ready!
        repo = Session::Repository.new
        session = repo.find(id)

        # Single-styled not-found error (#20), as in #show above.
        raise Thor::Error, "session not found: #{id}" if session.nil?

        self.class.destroy_with_confirm(session, repo: repo, ui: Rubino.ui, force: options[:force])
      end

      # ONE confirm-and-destroy flow for both surfaces (#183): the CLI verb
      # above and the in-chat `/sessions delete <id>`.
      def self.destroy_with_confirm(session, repo:, ui:, force: false)
        unless force
          confirmed = ui.confirm_destructive(
            "Delete session #{session[:id][0..7]} '#{session[:title] || "(untitled)"}'? " \
            "This will also remove its messages, events, and tool calls."
          )
          unless confirmed
            ui.info("Aborted.")
            return
          end
        end

        repo.destroy!(session[:id])
        ui.success("Deleted session #{session[:id][0..7]}.")
      end

      desc "compact ID", "Manually trigger compaction on a session"
      def compact(id)
        Rubino.ensure_database_ready!
        repo = Session::Repository.new
        session = repo.find(id)

        # Single-styled not-found error (#20), as in #show above.
        raise Thor::Error, "session not found: #{id}" if session.nil?

        Rubino.ui.info("Compacting session #{id}...")
        compressor = Context::Compressor.new(session_id: id)
        result = compressor.compact!
        Rubino.ui.compression_finished(result)
      end
    end
  end
end
