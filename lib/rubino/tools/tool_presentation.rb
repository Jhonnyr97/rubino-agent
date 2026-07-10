# frozen_string_literal: true

module Rubino
  module Tools
    # Neutral presentation descriptors — read by BOTH CLI and API renderers.
    # These are the stable contract; each tool declares its intent once and
    # the two UIs render it their own way.
    #
    #   class EditTool < Base
    #     class ToolPresentation < Tools::ToolPresentation
    #       def body_kind = :diff
    #       def stream_params? = true
    #     end
    #     presentation ToolPresentation
    #   end
    #
    # body_kind vocabulary (stable enum):
    #   :plain     — dimmed text, collapsed to preview_lines (CLI), raw string (API)
    #   :diff      — colorized +/-/@@ (CLI), structured diff (API/JSON)
    #   :json      — pretty-printed JSON block
    #   :table     — unicode-border table
    #   :markdown  — rendered markdown
    class ToolPresentation
      def initialize(config = Rubino.configuration)
        @config = config
      end

      # How the frontend renders the tool's output body.
      def body_kind = :plain

      # CLI: whether to open a live card and stream parameter values
      # as the LLM generates them (before execution starts).
      def stream_params? = false

      # CLI: whether the tool emits output chunks during execution
      # (shell stdout streaming).
      def stream_output? = false

      # Formats the approval-prompt string (header + body) for this tool.
      # Receives the display label (e.g. "edit", "echo (mcp:chaos)") and
      # the raw arguments hash. Returns a complete formatted string, or nil
      # to fall back to the executor's generic key-value formatter.
      #
      # Override in a tool's ToolPresentation subclass to show a diff
      # preview, content snippet, or any custom layout:
      #
      #   class ToolPresentation < Tools::ToolPresentationCLI
      #     def preview_arguments(label, arguments)
      #       # build and return formatted string, or nil
      #     end
      #   end
      def preview_arguments(_label, _arguments)
        nil
      end
    end
  end
end
