# frozen_string_literal: true

module Rubino
  module Tools
    # CLI-specific render hints — consumed only by UI::CLI.
    # Tools that need no CLI customization can omit this entirely;
    # Base defaults to ToolPresentationCLI.new with all defaults.
    #
    #   class ShellTool::ToolPresentation < Tools::ToolPresentationCLI
    #     def status_label = "executing command…"
    #   end
    class ToolPresentationCLI < ToolPresentation
      # Label shown in the animated status bar while the tool executes.
      # nil = use the tool name (e.g. "write", "shell").
      def status_label = nil

      # Phase marker for the status bar ticker.
      def status_phase = :tool

      # Maximum preview lines shown in the timeline.
      # nil = unlimited (for diffs where every line matters).
      def preview_lines
        @config.dig("display", "tool_output_preview_lines") || 30
      end

      def diff? = body_kind == :diff
    end
  end
end
