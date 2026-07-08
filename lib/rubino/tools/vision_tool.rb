# frozen_string_literal: true

require_relative "../llm/auxiliary_client"
require_relative "../attachments/classify"
require_relative "../attachments/policy"

module Rubino
  module Tools
    # Delegates image-understanding to a multimodal aux model so a text-only
    # primary can still "see" what the user uploaded. Implements the
    # agent-as-tool semantics from the OpenAI Agents SDK: the primary stays
    # in control, calls this tool with a focused question, and receives a
    # structured (text) reply — no conversation handoff, no shared history.
    #
    # The aux model is resolved from `auxiliary.vision` in config. Registry
    # hides this tool ONLY when no aux vision model is configured AND the
    # primary itself can't see (per Configuration#model_supports_vision?) —
    # the one case where calling it could only error. Whenever the primary
    # supports vision OR an aux model is set, the tool stays EXPOSED (see
    # Tools::Registry#aux_dependency_satisfied?), since the model may still
    # prefer to delegate to a better-suited aux model.
    class VisionTool < Base
      tool_name   "vision"
      description "Ask a multimodal model to describe or interpret an image. " \
                  "Use when you need to understand visual content (charts, screenshots, " \
                  "diagrams, photos). Provide an optional focused question to direct the " \
                  "analysis; default is a full markdown description."
      risk_level :low

      param :file_path, desc: "Absolute path to an image file (.png .jpg .jpeg .webp .gif .bmp)"
      param :question,  desc: "Optional focused question. Default: 'Describe what you see in markdown.'", required: false

      def execute(file_path:, question: "Describe what you see in markdown.")
        path     = file_path.to_s
        question = question.to_s

        return "Error: file_path is required" if path.empty?

        expanded = File.expand_path(path)
        # Vision sends the raw bytes off to the auxiliary
        # LLM, so an out-of-workspace image must be DENIED rather than read and
        # exfiltrated. Checked before existence so a file outside the sandbox
        # isn't even probed for presence (r5 MF-1 / r5c NEW-2).
        return outside_workspace_message(path) if outside_workspace?(expanded)
        return "Error: file not found: #{path}" unless File.exist?(expanded)
        return "Error: not a regular file: #{path}" unless File.file?(expanded)

        ext = File.extname(expanded).downcase
        unless LLM::ContentBuilder::SUPPORTED_IMAGE_TYPES.include?(ext)
          return "Error: unsupported image extension '#{ext}'. " \
                 "Supported: #{LLM::ContentBuilder::SUPPORTED_IMAGE_TYPES.join(", ")}"
        end

        # Egress kill-switch (#578): routing the bytes to the aux vision model
        # is data egress. When attachments.policy.aux_vision_egress is set to
        # false, refuse BEFORE reading/shipping anything so the operator's
        # opt-out is real and not a dead config key.
        unless Attachments::Policy.aux_vision_egress?
          return "Error: image egress is disabled by config " \
                 "(attachments.policy.aux_vision_egress: false). " \
                 "The vision tool will not send image bytes to the auxiliary model."
        end

        # Content-sniff BEFORE egress (#579): the extension check above can be
        # spoofed (a text/binary file renamed `.png`), and on the bare tool
        # path the raw bytes would otherwise reach the EXTERNAL aux/vision model
        # before the model itself rejects them — the bytes have already left the
        # host. Reuse Attachments::Classify (magic wins, fail-closed; same
        # detector the executor's native-attachment path uses) and reject when
        # the real content isn't an image, so nothing is shipped off-host.
        classification = Attachments::Classify.call(expanded)
        unless classification&.safe && classification.kind == :image
          return "Error: '#{path}' is not a valid image (extension spoof or corrupt file?). " \
                 "Its content is not a recognised image format, so nothing was sent to the vision model."
        end

        # Pass the image through ruby_llm's native `with:` slot (image_paths),
        # NOT as an OpenAI-style content array. ruby_llm's `ask` stringifies an
        # array content, so the base64 bytes would reach the model as TEXT and
        # it hallucinates (prod sessions 38/41: M3 saw the image perfectly when
        # called directly, but got a text blob through this path). image_paths
        # attaches the file as a real multimodal part — same route the primary
        # uses for native vision.
        response = LLM::AuxiliaryClient.new.call(
          task: :vision,
          messages: [{ role: "user", content: question }],
          image_paths: [expanded]
        )
        response.content.to_s
      rescue StandardError => e
        "Error calling vision model: #{e.class}: #{e.message}"
      end
    end
  end
end
