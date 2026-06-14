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
        guard_corrupt_database!
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
          # cwd (the launch dir) lets a multi-folder/multi-tab user tell which
          # project each session belongs to (r5 MF-4); home-collapsed and
          # terminal-escape-sanitized like the other stored fields.
          [self.class.safe(s[:id][0..7]),
           self.class.safe(s[:title] || "(untitled)"),
           self.class.safe(self.class.collapse_home(s[:cwd])),
           self.class.safe(s[:status]),
           self.class.safe(s[:message_count].to_s),
           self.class.safe(s[:updated_at] || s[:created_at])]
        end

        Rubino.ui.table(
          headers: %w[ID Title Dir Status Messages Updated],
          rows: rows
        )
      end

      desc "show ID", "Show session details"
      def show(id)
        guard_corrupt_database!
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
        ui.info("Dir: #{safe(collapse_home(session[:cwd]))}")
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

      # Home-collapsed display path for a session's launch dir. Returns a dash
      # for sessions created before the cwd column existed (NULL cwd) so the
      # column stays aligned.
      def self.collapse_home(path)
        return "—" if path.nil? || path.to_s.empty?

        home = Dir.home
        str = path.to_s
        str.start_with?(home) ? str.sub(home, "~") : str
      rescue ArgumentError
        path.to_s
      end

      desc "delete ID", "Permanently delete a session and all its messages/events"
      option :force, type: :boolean, default: false, aliases: "-f",
                     desc: "Skip the confirmation prompt"
      def delete(id)
        guard_corrupt_database!
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
        guard_corrupt_database!
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

      private

      # Turn a corrupt/malformed on-disk DB into a clean, actionable diagnostic
      # instead of leaking a raw Sequel/sqlite3 backtrace (HIGH-2). Without this
      # the first DB touch (Repository.new → connect → `PRAGMA journal_mode=WAL`)
      # throws SQLite3::CorruptException and dumps ~20 lines of trace. Thor prints
      # a Thor::Error's message to stderr and exits non-zero with no backtrace.
      def guard_corrupt_database!
        return unless Rubino.database.corrupt?

        raise Thor::Error,
              "database is corrupt (malformed image): #{Rubino.database.db_path}\n" \
              "Run `rubino setup` to quarantine it and recreate a fresh database."
      end
    end
  end
end
