# frozen_string_literal: true

require "time"

module Rubino
  module Commands
    module Handlers
      # The `/sessions` list/show/delete/picker surface plus the `/probe` and
      # `/branch` REPL signals, extracted from Commands::Executor (batch B).
      #
      # No-arg = list recent + how to resume; arg = resolve and resume in place.
      # Resuming returns a {resume_session_id:} signal the REPL acts on by
      # rebuilding its runner on that session (history replays). Reuses
      # Session::Repository#list and #find_by_id_or_title (which already raises
      # AmbiguousSessionError on >1 match).
      #
      # The management verbs (#183) reuse the CLI subcommands' logic
      # (CLI::SessionCommand.render / .destroy_with_confirm — ONE rendering and
      # ONE delete flow for both surfaces):
      #
      #   /sessions                → list (picker on a TTY) + resume
      #   /sessions --all          → list without the row cap
      #   /sessions show <id>      → details, without switching into it
      #   /sessions delete <id>    → delete (asks to confirm)
      #   /sessions rename <id> T  → set a human-readable title (#45)
      #   /sessions <id|title>     → resume
      class Sessions
        def initialize(ui:, runner:)
          @ui = ui
          @runner = runner
        end

        def handle_sessions(arguments)
          tokens = arguments.to_s.strip.split(/\s+/)
          all    = tokens.delete("--all") ? true : false
          return list_sessions(all: all) if tokens.empty?

          case tokens.first
          when "show"   then session_verb(tokens[1..].join(" "), "show") { |s| CLI::SessionCommand.render(s, ui: @ui) }
          when "delete" then session_verb(tokens[1..].join(" "), "delete") { |s| delete_session(s) }
          when "rename" then rename_session(tokens[1..])
          else resume_session(tokens.join(" "))
          end
        end

        # `/probe <text>` — the discoverable alias for the `? ` prefix. Bare
        # `/probe` only teaches the prefix (the one-keystroke common case); with
        # text, signal the REPL to run the ephemeral side-inference and discard.
        def handle_probe(arguments)
          text = arguments.to_s.strip
          if text.empty?
            @ui.info("Ask an ephemeral side-question that is NOT saved to this session.")
            @ui.info("Tip: just start a line with '? ' — e.g.  ? is this lib MIT or GPL?")
            return :handled
          end

          { probe: text }
        end

        # `/branch [name]` — fork the current session here into a NEW saved one
        # and switch into it. The REPL holds the runner/session, so we just pass
        # the optional title along on the branch signal.
        def handle_branch(arguments)
          title = arguments.to_s.strip
          { branch: true, title: title.empty? ? nil : title }
        end

        private

        # Resolves the id/title for a /sessions verb (same matcher resume uses,
        # so short ids and title substrings work) and yields the session row;
        # prints the usage/not-found/ambiguous error otherwise. Always :handled —
        # the verbs never fall through to the unknown-command path (#34).
        def session_verb(query, verb)
          if query.nil? || query.empty?
            @ui.info("Usage: /sessions #{verb} <id>")
            return :handled
          end

          session = Session::Repository.new.find_by_id_or_title(query)
          if session.nil?
            @ui.error("no session matching #{query.inspect}.")
            @ui.info("List them with /sessions")
          else
            yield session
          end
          :handled
        rescue Rubino::AmbiguousSessionError => e
          @ui.error(e.message)
          :handled
        rescue Sequel::DatabaseError => e
          @ui.error("couldn't look up that session: #{db_error_summary(e)}")
          :handled
        end

        # Deletes a session in-chat via the SAME confirm-and-destroy flow the
        # `rubino sessions delete` CLI verb runs (#183). The session the live
        # runner sits on is refused — deleting the history under the active
        # runner would corrupt the running conversation; /new first.
        def delete_session(session)
          if @runner&.session&.dig(:id) == session[:id]
            @ui.error("that is the ACTIVE session — start a new one first (/new), then delete it.")
            return
          end

          CLI::SessionCommand.destroy_with_confirm(session, repo: Session::Repository.new, ui: @ui)
        end

        # `/sessions rename <id|title> <new title>` — give a session a
        # human-readable title (#45). A session is auto-titled from its first
        # user message, so a throwaway opener ("say hi") leaves a useless
        # `/sessions` row; both Hermes (`/title`) and Claude Code (session
        # rename) let the user fix it explicitly. The id/title matcher and
        # not-found/ambiguous handling are shared with show/delete; the new
        # title is written through Session::Repository#update, which scrubs it.
        # The first token is the session selector, the rest is the new title.
        def rename_session(tokens)
          query = tokens.first.to_s
          new_title = tokens[1..].to_a.join(" ").strip
          if query.empty? || new_title.empty?
            @ui.info("Usage: /sessions rename <id> <new title>")
            return :handled
          end

          session_verb(query, "rename") do |session|
            Session::Repository.new.update(session[:id], title: new_title)
            # If this is the session the live runner sits on, refresh its
            # in-memory title too. /status reads @runner.session[:title] (a
            # boot-time snapshot the rename never touched), so without this it
            # kept showing the STALE auto-title until a compaction forked a new
            # session id (S7 F3).
            live = @runner&.session
            live[:title] = new_title if live && live[:id] == session[:id]
            @ui.success(%(Renamed #{session[:id][0..7]} → "#{session_title(session.merge(title: new_title))}"))
          end
        end

        def list_sessions(all: false)
          sessions = Session::Repository.new.list(limit: all ? nil : sessions_list_limit)
          if sessions.empty?
            @ui.info("No past sessions yet.")
            return :handled
          end

          # ONE surface, not two (#40): on a real terminal the arrow-key picker
          # IS the list (Enter resumes, Esc cancels — #73, letters filter), with
          # Created/Status folded into each row, so the same sessions are never
          # rendered twice (static table + picker). Off a TTY the static table +
          # typed-shortcut fallback renders instead.
          return sessions_table_fallback(sessions) unless interactive_terminal?

          choices = sessions.map { |s| [session_choice_label(s), s[:id]] }
          chosen  = @ui.select("Resume which session? (Esc to cancel)", choices)
          if chosen
            session = sessions.find { |s| s[:id] == chosen }
            @ui.success(%(Resuming #{chosen[0..7]}  "#{session_title(session)}")) if session
            return { resume_session_id: chosen }
          end

          @ui.info("Resume: /sessions <id|title>   ·   /sessions show|delete|rename <id>")
          :handled
        end

        # Static fallback for non-interactive callers (pipes / Null UI): the
        # bordered table the picker replaces on a TTY. Leads with the identifying
        # fields (ID, Title, Created) so a narrow-term card fallback scans well —
        # the key field first, not buried (#84).
        def sessions_table_fallback(sessions)
          rows = sessions.map do |s|
            [s[:id].to_s[0..7], session_title(s), session_dir(s),
             s[:created_at].to_s, s[:status].to_s, s[:message_count].to_s]
          end
          @ui.table(headers: %w[ID Title Dir Created Status Msgs], rows: rows)
          @ui.info("Resume: /sessions <id|title>   ·   /sessions show|delete|rename <id>")
          :handled
        end

        # One picker row: short id + title + message count + recency (and status
        # when not yet ended), so the highlighted entry is identifiable at a
        # glance and the picker is a clean superset of the old static table (#40).
        def session_choice_label(session)
          id    = session[:id].to_s[0..7]
          title = session_title(session)
          msgs  = session[:message_count]
          dir   = session_dir(session)
          meta  = [
            ("#{msgs} msg#{"s" if msgs != 1}" if msgs),
            (dir unless dir == "—"),
            session_age(session),
            (session[:status].to_s unless ["", "ended"].include?(session[:status].to_s))
          ].compact.join(" · ")
          meta.empty? ? "#{id}  #{title}" : "#{id}  #{title}  (#{meta})"
        end

        # "Created" humanized for the picker row — "5m ago" scans better than a
        # raw ISO timestamp in a recency-ordered list (#40). nil when unparseable.
        def session_age(session)
          created = session[:created_at]
          created = Time.parse(created.to_s) unless created.is_a?(Time)
          "#{Rubino::Util::Duration.human_duration(Time.now - created)} ago"
        rescue StandardError
          nil
        end

        def resume_session(query)
          session = Session::Repository.new.find_by_id_or_title(query)
          if session.nil?
            @ui.error("no session matching #{query.inspect}.")
            @ui.info("List them with /sessions")
            return :handled
          end

          @ui.success(%(Resuming #{session[:id][0..7]}  "#{session_title(session)}"))
          { resume_session_id: session[:id] }
        rescue Rubino::AmbiguousSessionError => e
          @ui.error(e.message)
          :handled
        rescue Sequel::DatabaseError => e
          @ui.error("couldn't look up that session: #{db_error_summary(e)}")
          :handled
        end

        # A one-line summary of a Sequel::DatabaseError for the chat surface
        # (#498). The chat session-resolution path now fully parameterizes its
        # queries, but any residual driver-level fault (a corrupt FTS index, a
        # tokenizer rejecting an exotic byte) must still reach the user as a
        # single clean line — never a raw `SQLite3::SQLException: ...` plus a
        # multi-line backtrace. Strip to the innermost driver message.
        def db_error_summary(error)
          (error.cause || error).message.to_s.lines.first.to_s.strip
        end

        # A session title is auto-generated from the conversation, so it is
        # attacker-influenceable: a raw `\e]0;…\a` / `\e[2J` in it would hijack
        # the window title or clear the screen the moment it reached the
        # `info`/`success`/picker funnels (none of which sanitize) — CWE-150,
        # R4-N2. Neutralize to caret notation at this single title funnel, which
        # every title-printing path (resume, picker label, Resuming success)
        # flows through.
        def session_title(session)
          title = Rubino::Util::Output.sanitize_terminal(session[:title].to_s).strip
          title.empty? ? "(untitled)" : title
        end

        # The session's launch dir (r5 MF-4), home-collapsed and terminal-escape
        # sanitized for display in the picker/table. "—" for pre-cwd-column rows.
        def session_dir(session)
          raw = session[:cwd].to_s
          return "—" if raw.empty?

          home = Dir.home
          collapsed = raw.start_with?(home) ? raw.sub(home, "~") : raw
          Rubino::Util::Output.sanitize_terminal(collapsed)
        rescue StandardError
          Rubino::Util::Output.sanitize_terminal(session[:cwd].to_s)
        end

        # The bare-list row cap (#183): configurable (`sessions.list_limit`) and
        # liftable per call with `/sessions --all` — no longer hardwired to 10.
        def sessions_list_limit
          limit = Rubino.configuration.dig("sessions", "list_limit").to_i
          limit.positive? ? limit : 10
        rescue StandardError
          10
        end

        # True when the REPL owns a real interactive terminal (so the arrow-key
        # picker makes sense). Off a TTY we render the static table fallback.
        def interactive_terminal?
          $stdin.respond_to?(:tty?) && $stdin.tty? && $stdout.respond_to?(:tty?) && $stdout.tty?
        rescue StandardError
          false
        end
      end
    end
  end
end
