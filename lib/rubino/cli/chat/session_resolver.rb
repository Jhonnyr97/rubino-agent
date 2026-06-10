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
            # losing context. When there genuinely is none, tell the user instead
            # of silently starting over.
            @auto_resumed_session = Session::Repository.new.latest_resumable
            return @auto_resumed_session[:id] if @auto_resumed_session

            warn pastel.yellow("No previous session to continue — starting a new one.")
            return nil
          end

          # --new forces a brand-new session; otherwise a BARE interactive `chat`
          # auto-resumes the most recent resumable session so a user who closed
          # the terminal continues where they left off. nil ⇒ no prior session
          # (true first run) ⇒ fresh session + welcome panel.
          return nil if opt(:new) || !auto_resume

          @auto_resumed_session = Session::Repository.new.latest_resumable
          @auto_resumed_session&.dig(:id)
        end

        # True when the chat was started against an existing session (--resume /
        # --continue / explicit --session / bare-chat auto-resume): show its
        # history rather than the first-run welcome panel.
        def resuming_session?
          !!(opt(:session) || opt(:resume) || opt(:r) || opt(:continue) || opt(:c) ||
             @auto_resumed_session)
        end

        # One-liner shown when a bare `chat` auto-resumed the last session (#99),
        # so the continuation is never silent and the user knows how to opt out.
        def print_auto_resume_line(ui, session)
          return unless session

          title = session[:title].to_s.strip
          label = title.empty? ? session[:id][0..7] : %("#{title}")
          ui.status("▸ resuming #{label} (#{session[:id][0..7]}) — /new for a fresh session")
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
          return unless session_id

          messages = ::Rubino::Session::Store.new.for_session(session_id)
          return if messages.empty?

          ui.status("Loaded #{messages.size} prior message#{"s" if messages.size != 1}")
          ui.separator

          messages.each do |msg|
            at = parse_msg_timestamp(msg.created_at)
            case msg.role.to_s
            when "user"
              ui.replay_user_input(msg.content, at: at)
            when "assistant"
              next if msg.content.nil? || msg.content.to_s.empty?

              # Render the prior assistant turn as markdown, same as a live reply —
              # not the old box (which the M2 redesign repurposed into a "● running"
              # tool-style row, so resume showed assistant turns as fake tool runs
              # with raw markdown).
              ui.assistant_text(msg.content)
            when "tool"
              name      = msg.tool_name || "tool"
              arguments = msg.metadata.is_a?(Hash) ? msg.metadata[:arguments] : nil
              ui.tool_started(name, arguments: arguments, at: at)
              ui.tool_finished(
                name,
                result: ::Rubino::Tools::Result.success(
                  name: name,
                  call_id: msg.tool_call_id,
                  output: msg.content.to_s
                )
              )
            end
          end

          ui.separator
        end

        private

        def opt(key)
          @options[key] || @options[key.to_s]
        end

        def pastel
          @pastel ||= Pastel.new
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
