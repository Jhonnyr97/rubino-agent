# frozen_string_literal: true

require "time"

module Rubino
  module Session
    # The ONE arrow-key session picker, shared by both resume surfaces (#40):
    # the in-REPL `/sessions` chooser (Commands::Handlers::Sessions) and the
    # CLI `rubino sessions` bare-on-a-TTY entry (CLI::SessionCommand). Both feed
    # it a session list and get back the chosen session id (or nil on cancel),
    # so the selection UI — the row label, the prompt, the Esc-cancels frame
    # erase in UI#select — lives in exactly one place instead of being copied.
    #
    # Pure presentation + selection: it does NOT resolve/replay/boot a session.
    # Each caller hands the chosen id to its own resume path (the REPL rebuilds
    # its runner in place; the CLI boots `ChatCommand` exactly as
    # `rubino chat --session <id>` does).
    class Picker
      PROMPT = "Resume which session? (Esc to cancel)"

      def initialize(ui:)
        @ui = ui
      end

      # Presents the picker over +sessions+ (already filtered/limited by the
      # caller) and returns the chosen session id, or nil when the user
      # cancelled (Esc) or the UI has no interactive select. Each row is
      # `session_choice_label` — short id + title + message count + dir +
      # recency — so the highlighted entry is identifiable at a glance.
      def pick(sessions)
        return nil if sessions.nil? || sessions.empty?

        choices = sessions.map { |s| [self.class.session_choice_label(s), s[:id]] }
        @ui.select(PROMPT, choices)
      end

      # One picker row: short id + title + message count + dir + recency (and
      # status when not yet ended), so the highlighted entry is identifiable at
      # a glance and the picker is a clean superset of the old static table
      # (#40). A class method so both the instance picker and the in-REPL
      # `session_choice_label` delegate to the SAME formatting.
      def self.session_choice_label(session)
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

      # A session title is auto-generated from the conversation, so it is
      # attacker-influenceable: a raw `\e]0;…\a` / `\e[2J` in it would hijack
      # the window title or clear the screen the moment it reached the
      # picker/info funnels (none of which sanitize) — CWE-150, R4-N2.
      # Neutralize to caret notation at this single title funnel.
      def self.session_title(session)
        title = Rubino::Util::Output.sanitize_terminal(session[:title].to_s).strip
        return "(untitled)" if title.empty?

        # Length-cap on render (#581) as belt-and-suspenders: the rename write
        # seam now bounds new titles, but pre-fix or other-path titles could
        # still be 2000 chars and soft-wrap the picker across the whole screen.
        Rubino::Util::Output.elide(title, Rubino::Session::Repository::TITLE_MAX_CHARS)
      end

      # The session's launch dir (r5 MF-4), home-collapsed and terminal-escape
      # sanitized for display. "—" for pre-cwd-column rows.
      def self.session_dir(session)
        raw = session[:cwd].to_s
        return "—" if raw.empty?

        home = Dir.home
        collapsed = raw.start_with?(home) ? raw.sub(home, "~") : raw
        Rubino::Util::Output.sanitize_terminal(collapsed)
      rescue StandardError
        Rubino::Util::Output.sanitize_terminal(session[:cwd].to_s)
      end

      # "Created" humanized for the picker row — "5m ago" scans better than a
      # raw ISO timestamp in a recency-ordered list (#40). nil when unparseable.
      def self.session_age(session)
        created = session[:created_at]
        created = Time.parse(created.to_s) unless created.is_a?(Time)
        "#{Rubino::Util::Duration.human_duration(Time.now - created)} ago"
      rescue StandardError
        nil
      end
    end
  end
end
