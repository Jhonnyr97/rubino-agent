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

          @ui.info("Resume: /sessions <id|title>   ·   /sessions show|delete <id>")
          :handled
        end

        # Static fallback for non-interactive callers (pipes / Null UI): the
        # bordered table the picker replaces on a TTY. Leads with the identifying
        # fields (ID, Title, Created) so a narrow-term card fallback scans well —
        # the key field first, not buried (#84).
        def sessions_table_fallback(sessions)
          rows = sessions.map do |s|
            [s[:id].to_s[0..7], session_title(s), s[:created_at].to_s, s[:status].to_s, s[:message_count].to_s]
          end
          @ui.table(headers: %w[ID Title Created Status Msgs], rows: rows)
          @ui.info("Resume: /sessions <id|title>   ·   /sessions show|delete <id>")
          :handled
        end

        # One picker row: short id + title + message count + recency (and status
        # when not yet ended), so the highlighted entry is identifiable at a
        # glance and the picker is a clean superset of the old static table (#40).
        def session_choice_label(session)
          id    = session[:id].to_s[0..7]
          title = session_title(session)
          msgs  = session[:message_count]
          meta  = [
            ("#{msgs} msg#{"s" if msgs != 1}" if msgs),
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
        end

        def session_title(session)
          title = session[:title].to_s.strip
          title.empty? ? "(untitled)" : title
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
