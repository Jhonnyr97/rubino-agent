# frozen_string_literal: true

require "json"
require "time"

module Rubino
  module Session
    # Serializes one session's transcript to clean markdown — the `/export`
    # backend. Deliberately minimal: user/assistant turns verbatim, tool
    # calls and tool results as one-liners, system rows (prompt scaffolding,
    # compaction summaries) omitted. Reasoning never reaches the message
    # store, so a transcript export is reasoning-free by construction.
    class Exporter
      # Tool-call arguments are context, not payload — clamp the one-liner.
      ARGS_PREVIEW_CHARS = 120

      def initialize(session, store: Store.new)
        @session = session
        @store = store
      end

      # The full markdown document for the session.
      def markdown
        lines = header
        @store.for_session(@session[:id]).each do |msg|
          lines.concat(render(msg))
        end
        "#{lines.join("\n")}\n"
      end

      # Writes #markdown to +path+ (default ./rubino-session-<id8>.md in the
      # current directory) and returns the absolute path written.
      def write(path = nil)
        target = File.expand_path(path.to_s.empty? ? default_filename : path.to_s)
        File.write(target, markdown)
        target
      end

      def default_filename
        "rubino-session-#{@session[:id].to_s[0, 8]}.md"
      end

      private

      def header
        meta = ["- session: #{@session[:id]}"]
        meta << "- title: #{@session[:title]}" if @session[:title]
        meta << "- model: #{@session[:model]}" if @session[:model]
        meta << "- exported: #{Time.now.utc.iso8601}"
        ["# rubino session #{@session[:id].to_s[0, 8]}", "", *meta, ""]
      end

      def render(msg)
        case msg.role.to_s
        when "user" then ["## User", "", msg.content.to_s, ""]
        when "assistant" then render_assistant(msg)
        when "tool" then ["- tool result: `#{msg.tool_name || "tool"}` (#{msg.content.to_s.length} chars)", ""]
        else []
        end
      end

      # The assistant turn's text, then each tool call it made as a one-liner.
      # A pure tool-call turn (no visible text) keeps just the call lines.
      def render_assistant(msg)
        lines = ["## Assistant", ""]
        text = msg.content.to_s
        lines.push(text, "") unless text.empty?
        tool_calls(msg).each do |tc|
          lines.push("- tool call: `#{tc[:name]}` #{args_preview(tc[:arguments])}".rstrip, "")
        end
        lines
      end

      def tool_calls(msg)
        calls = msg.metadata.is_a?(Hash) ? msg.metadata[:tool_calls] : nil
        Array(calls).grep(Hash)
      end

      def args_preview(arguments)
        return "" if arguments.nil? || arguments == {}

        text = arguments.is_a?(String) ? arguments : JSON.generate(arguments)
        text = "#{text[0, ARGS_PREVIEW_CHARS]}…" if text.length > ARGS_PREVIEW_CHARS
        "`#{text}`"
      rescue StandardError
        ""
      end
    end
  end
end
