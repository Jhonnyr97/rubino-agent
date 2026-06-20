# frozen_string_literal: true

require "time"
require "pastel"

module Rubino
  module CLI
    module Chat
      # Resolves which session a chat invocation runs against (--session /
      # --resume / --continue / bare-chat auto-resume) and replays a resumed
      # session's history through the UI, extracted from ChatCommand (#17).
      # Also owns the resume-facing one-liners (the auto-resume notice and the
      # exit-time resume hint).
      class SessionResolver
        def initialize(options)
          @options = options
        end

        # The session a bare-`chat` auto-resume / --continue picked, when one
        # was found. run_interactive gates the auto-resume notice on this.
        attr_reader :auto_resumed_session

        # Resolves which session this invocation should run against. +auto_resume+
        # enables the bare-`chat` auto-resume (#99) — only the interactive REPL
        # opts in; one-shot (`-q`/scripted) keeps the old "fresh unless asked"
        # behaviour so automation isn't silently hijacked onto a past session.
        def resolve_session_id(auto_resume: false)
          # Reap sessions orphaned by a hard kill (SIGKILL) or a closed terminal
          # whose SIGHUP never landed (#11): end any "active" row whose owning
          # process is gone before we resolve a resume target, so --continue /
          # auto-resume never treats a dead session as live.
          Session::Repository.new.reap_orphaned_active!

          id = opt(:session)
          return id if id

          resume = opt(:resume) || opt(:r)
          return resume if resume

          if opt(:continue) || opt(:c)
            # Explicit --continue/-c resumes the same session a bare `chat`
            # auto-resume would (#43): the latest RESUMABLE session (any status,
            # message_count > 0), not just an "active" one — otherwise a cleanly
            # ended prior session is invisible and -c silently forks a fresh one,
            # losing context. SCOPED to the launch dir (r5 MF-4 / C-1) so -c in
            # folder B never resumes folder A's conversation, and a session a
            # different live tab is still writing is skipped (no two-tab stomp).
            # When there genuinely is none for this dir, tell the user instead of
            # silently starting over.
            @auto_resumed_session = Session::Repository.new.latest_resumable_for_cwd
            return @auto_resumed_session[:id] if @auto_resumed_session

            warn pastel.yellow("No previous session to continue in this directory — starting a new one.")
            return nil
          end

          # --new forces a brand-new session; otherwise a BARE interactive `chat`
          # auto-resumes the most recent resumable session FOR THIS dir so a user
          # who closed the terminal continues where they left off — without ever
          # grabbing another folder's session (r5 MF-4 / C-1). nil ⇒ no prior
          # session for this dir (true first run here) ⇒ fresh session + welcome.
          return nil if opt(:new) || !auto_resume

          @auto_resumed_session = Session::Repository.new.latest_resumable_for_cwd
          @auto_resumed_session&.dig(:id)
        end

        # True when the chat was started against an existing session (--resume /
        # --continue / explicit --session / bare-chat auto-resume): show its
        # history rather than the first-run welcome panel.
        def resuming_session?
          !!(opt(:session) || opt(:resume) || opt(:r) || opt(:continue) || opt(:c) ||
             @auto_resumed_session)
        end

        # Prominent one-line banner shown when a bare `chat` auto-resumed the
        # last session (#99, F2): make it OBVIOUS which session was picked up so
        # a dev never accidentally continues/pollutes an old one. Carries the
        # SHORT id, the message count, and the cwd it belongs to — the three
        # facts a "wait, what session am I in?" moment needs — plus how to start
        # fresh. Rendered as a warning (not dim status) so it actually stands out
        # against the resumed history that follows.
        def print_auto_resume_line(ui, session)
          return unless session

          id     = session[:id].to_s[0..7]
          msgs   = session[:message_count].to_i
          msgcnt = "#{msgs} msg#{"s" if msgs != 1}"
          cwd    = pretty_cwd(session[:cwd])
          where  = cwd ? ", #{cwd}" : ""
          banner = "▸ resumed session #{id} (#{msgcnt}#{where}) — /new for fresh"
          ui.respond_to?(:warning) ? ui.warning(banner) : ui.status(banner)
        end

        # On exit, hand the user back the exact command to return to this chat.
        # Claude Code prints no equivalent hint; without this, the session id
        # is buried in ~/.claude state and the user has to guess at --resume
        # or scroll back through history. Prefer the human-friendly title when
        # one is set; fall back to the id otherwise.
        def print_resume_hint(ui, session)
          return unless session

          id    = session[:id]
          title = session[:title]
          handle = title && !title.to_s.strip.empty? ? %("#{title}") : id
          return unless handle

          ui.info("Resume with: rubino chat --resume #{handle}")
        end

        # --- Session history replay (resume / continue) ---
        #
        # PromptAssembler feeds the past turns to the model on every request, but
        # the inline REPL never printed them. On --resume the terminal looked
        # empty even though the model had full context. Replay user, assistant
        # and tool messages through the existing UI methods so the scrolled-back
        # transcript matches what the user originally saw.
        def print_session_history(ui, session_id)
          replay_session(ui, session_id)
        end

        # Replay a session's persisted transcript through the live UI render hooks
        # so the scrolled-back history matches what the user originally saw. Shared
        # by --resume (#print_session_history) and the agent-attach view switch,
        # which clears the screen and replays the SELECTED agent's own session.
        def replay_session(ui, session_id)
          return unless session_id

          replay_messages(ui, ::Rubino::Session::Store.new.for_session(session_id))
        end

        # Replay an ALREADY-FETCHED message list (the attach view passes the
        # child's `entry.messages` straight through, no second store hit). A no-op
        # on an empty list, framed by the same "Loaded N" status + separators the
        # resume path shows.
        def replay_messages(ui, messages)
          messages = Array(messages)
          return if messages.empty?

          ui.status("Loaded #{messages.size} prior message#{"s" if messages.size != 1}")
          ui.separator
          messages.each { |msg| replay_message(ui, msg) }
          ui.separator
        end

        private

        # Replay ONE persisted message through the matching live UI render hook.
        # Extracted from #replay_session so a single message renders identically
        # whether it comes from a resumed main session or an attached agent's.
        def replay_message(ui, msg)
          at = parse_msg_timestamp(msg.created_at)
          case msg.role.to_s
          when "user"
            # A `!` bang command persisted its <bash-input>/<bash-stdout> context
            # messages as user rows; replay them as the `! <cmd>` echo + dim output
            # block, never the raw tags.
            return if BangShell.replay(ui, msg.content, at: at)

            ui.replay_user_input(msg.content, at: at)
          when "assistant"
            return if msg.content.nil? || msg.content.to_s.empty?

            # Render the prior assistant turn as markdown, same as a live reply —
            # not the old box (which the M2 redesign repurposed into a "● running"
            # tool-style row, so resume showed assistant turns as fake tool runs
            # with raw markdown).
            ui.assistant_text(msg.content)
          when "tool"
            name      = msg.tool_name || "tool"
            arguments = msg.metadata.is_a?(Hash) ? msg.metadata[:arguments] : nil
            ui.tool_started(name, arguments: arguments, at: at)
            ui.tool_finished(name, result: replay_tool_result(msg, name))
          end
        end

        # Rebuilds the stored tool message as a Tools::Result carrying its
        # ORIGINAL outcome, so #tool_finished replays the SAME glyph the live
        # session showed — a denied/failed tool replays with the red ✗
        # ("✗ … denied — not executed"), not a blanket green ✓ (the replay path
        # used to wrap every row as Result.success). The outcome comes from the
        # persisted metadata (status / error_code, written by Loop#persist_tool_result);
        # rows that pre-date that field fall back to inferring a failure from the
        # output text (a "denied"/"Error:" body), so old sessions also replay
        # correctly rather than always green.
        def replay_tool_result(msg, name)
          meta    = msg.metadata.is_a?(Hash) ? msg.metadata : {}
          status  = (meta[:status] || meta["status"]).to_s
          code    = meta[:error_code] || meta["error_code"]
          output  = msg.content.to_s
          call_id = msg.tool_call_id

          case status
          when "denied"
            ::Rubino::Tools::Result.new(name: name, call_id: call_id, output: output, status: :denied)
          when "error", "failed"
            ::Rubino::Tools::Result.new(name: name, call_id: call_id, output: output,
                                        status: :error, error_code: code&.to_sym)
          when "success", "completed"
            ::Rubino::Tools::Result.success(name: name, call_id: call_id, output: output,
                                            error_code: code&.to_sym)
          else
            # Legacy rows (no persisted status): infer from the output text so a
            # denied/errored tool still replays as ✗ instead of a false ✓.
            replay_result_from_text(name, call_id, output)
          end
        end

        # Best-effort outcome inference for tool rows persisted before the
        # status/error_code metadata existed: a "denied"/"blocked …not run"
        # body → :denied; an "Error:"-prefixed body → :error; everything else
        # is treated as a successful run (the common case).
        def replay_result_from_text(name, call_id, output)
          text = output.to_s
          if text.start_with?("Tool execution denied", "Tool execution blocked")
            ::Rubino::Tools::Result.new(name: name, call_id: call_id, output: text, status: :denied)
          elsif text.start_with?("Error:")
            ::Rubino::Tools::Result.new(name: name, call_id: call_id, output: text, status: :error)
          else
            ::Rubino::Tools::Result.success(name: name, call_id: call_id, output: text)
          end
        end

        def opt(key)
          @options[key] || @options[key.to_s]
        end

        def pastel
          @pastel ||= Pastel.new
        end

        # Abbreviate the session's cwd for the resume banner: collapse $HOME to
        # ~ and show just the basename's last two segments so a deep path
        # doesn't blow the line width. nil for a session with no recorded cwd.
        def pretty_cwd(cwd)
          path = cwd.to_s.strip
          return nil if path.empty?

          home = Dir.home
          path = path.sub(%r{\A#{Regexp.escape(home)}(?=/|\z)}, "~") if home && !home.empty?
          segs = path.split("/")
          segs.length > 3 ? "…/#{segs.last(2).join("/")}" : path
        end

        # Best-effort parse of the timestamp the DB stored on a Message.
        # Sequel hands these back as either a Time or an ISO8601 String
        # depending on adapter and column type; the replay code wants a Time
        # to feed to `ui.box_open(at:)`. Anything unparseable falls back to nil
        # and the header shows "now" — better than crashing on replay.
        def parse_msg_timestamp(value)
          return value if value.is_a?(Time)
          return nil if value.nil? || value.to_s.empty?

          Time.parse(value.to_s)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
