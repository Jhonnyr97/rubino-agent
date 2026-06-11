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
        when "tool" then render_tool(msg)
        else []
        end
      end

      # The assistant turn's visible text. The tool-call one-liner is emitted by
      # #render_tool from the `tool`-role result row (which carries `tool_name` +
      # `arguments` on BOTH the streaming and non-streaming paths), NOT here from
      # the assistant row's `tool_calls` metadata — that metadata is absent on the
      # streaming path (the default; the call is emitted mid-stream), so reading
      # it left the call one-liner dead in every real export (#216). A pure
      # tool-call turn has no visible text, so this renders just the heading.
      def render_assistant(msg)
        lines = ["## Assistant", ""]
        text = msg.content.to_s
        lines.push(text, "") unless text.empty?
        lines
      end

      # A `tool`-role row renders its call one-liner (reconstructed from the
      # row's own `tool_name` + `arguments` metadata) followed by its result
      # one-liner. The call line is the only place the command/args survive on
      # the streaming path, where the assistant turn persists without
      # `tool_calls` (#216).
      def render_tool(msg)
        name = msg.tool_name || "tool"
        args = msg.metadata.is_a?(Hash) ? msg.metadata[:arguments] : nil
        [
          "- tool call: `#{name}` #{args_preview(args)}".rstrip, "",
          "- tool result: `#{name}` (#{msg.content.to_s.length} chars)", ""
        ]
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
