# frozen_string_literal: true

module Rubino
  module Tools
    # Delegates image-understanding to a multimodal aux model so a text-only
    # primary can still "see" what the user uploaded. Implements the
    # agent-as-tool semantics from the OpenAI Agents SDK: the primary stays
    # in control, calls this tool with a focused question, and receives a
    # structured (text) reply — no conversation handoff, no shared history.
    #
    # Built on Rubino::Tool — the egress guards (workspace containment,
    # extension allowlist, egress kill-switch, content-sniff) are applied
    # automatically by the `image` param type BEFORE #execute sees the
    # argument.  ~90 lines → ~24 lines.
    class VisionTool < Rubino::Tool
      describe "Ask a multimodal model to describe or interpret an image. " \
               "Use when you need to understand visual content (charts, screenshots, " \
               "diagrams, photos). Provide an optional focused question to direct the " \
               "analysis; default is a full markdown description."

      image :file_path, "Absolute path to an image file (.png .jpg .jpeg .webp .gif .bmp)"
      string :question, "Optional focused question. Default: 'Describe what you see in markdown.'",
             required: false

      uses_aux :vision

      def execute(file_path:, question: "Describe what you see in markdown.")
        expanded = File.expand_path(file_path.to_s)
        response = ask_aux(question.to_s, image: expanded)
        response.content.to_s
      rescue StandardError => e
        "Error calling vision model: #{e.class}: #{e.message}"
      end
    end
  end
end
