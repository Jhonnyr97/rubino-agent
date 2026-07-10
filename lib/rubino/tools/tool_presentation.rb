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
    end
  end
end
