# frozen_string_literal: true

require_relative "../llm/auxiliary_client"

module Rubino
  module Tools
    # Delegates image-understanding to a multimodal aux model so a text-only
    # primary can still "see" what the user uploaded. Implements the
    # agent-as-tool semantics from the OpenAI Agents SDK: the primary stays
    # in control, calls this tool with a focused question, and receives a
    # structured (text) reply — no conversation handoff, no shared history.
    #
    # The aux model is resolved from `auxiliary.vision` in config. When the
    # primary already supports vision (per Configuration#model_supports_vision?)
    # AND no aux is configured, Registry hides this tool — there's no useful
    # delegation to perform.
    class VisionTool < Base
      def name
        "vision"
      end

      def description
        "Ask a multimodal model to describe or interpret an image. " \
        "Use when you need to understand visual content (charts, screenshots, " \
        "diagrams, photos). Provide an optional focused question to direct the " \
        "analysis; default is a full markdown description."
      end

      def input_schema
        {
          type: "object",
          properties: {
            file_path: {
              type: "string",
              description: "Absolute path to an image file (.png .jpg .jpeg .webp .gif .bmp)"
            },
            question: {
              type: "string",
              description: "Optional focused question. Default: 'Describe what you see in markdown.'"
            }
          },
          required: %w[file_path]
        }
      end

      def risk_level
        :low
      end

      def call(arguments)
        path     = (arguments["file_path"] || arguments[:file_path]).to_s
        question = (arguments["question"]  || arguments[:question] ||
                    "Describe what you see in markdown.").to_s

        return "Error: file_path is required" if path.empty?

        expanded = File.expand_path(path)
        return "Error: file not found: #{path}" unless File.exist?(expanded)
        return "Error: not a regular file: #{path}" unless File.file?(expanded)

        ext = File.extname(expanded).downcase
        unless LLM::ContentBuilder::SUPPORTED_IMAGE_TYPES.include?(ext)
          return "Error: unsupported image extension '#{ext}'. " \
                 "Supported: #{LLM::ContentBuilder::SUPPORTED_IMAGE_TYPES.join(', ')}"
        end

        # Pass the image through ruby_llm's native `with:` slot (image_paths),
        # NOT as an OpenAI-style content array. ruby_llm's `ask` stringifies an
        # array content, so the base64 bytes would reach the model as TEXT and
        # it hallucinates (prod sessions 38/41: M3 saw the image perfectly when
        # called directly, but got a text blob through this path). image_paths
        # attaches the file as a real multimodal part — same route the primary
        # uses for native vision.
        response = LLM::AuxiliaryClient.new.call(
          task:        :vision,
          messages:    [{ role: "user", content: question }],
          image_paths: [expanded]
        )
        response.content.to_s
      rescue StandardError => e
        "Error calling vision model: #{e.class}: #{e.message}"
      end
    end
  end
end
