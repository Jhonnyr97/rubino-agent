# frozen_string_literal: true

module Rubino
  module LLM
    # Image-path helpers shared by the vision tool, run executor, and the
    # interaction lifecycle: extension matching, in-text image extraction,
    # and the model-family vision heuristic.
    class ContentBuilder
      SUPPORTED_IMAGE_TYPES = %w[.png .jpg .jpeg .gif .webp .bmp].freeze

      # True when the path has a recognised image extension. Centralised here
      # so Executor and tools share one definition.
      def self.image_file?(path)
        return false if path.nil? || path.to_s.empty?

        SUPPORTED_IMAGE_TYPES.include?(File.extname(path.to_s).downcase)
      end

      # Detects image references in text (file paths or URLs)
      # Extracts them and returns [cleaned_text, image_list]
      def self.extract_images(text)
        images = []
        cleaned = text.dup

        # Match file paths to images: /path/to/image.png or ./image.jpg
        cleaned.gsub!(/(?:^|\s)((?:\/|\.\/|\~\/)[^\s]+\.(?:png|jpg|jpeg|gif|webp|bmp))/i) do
          path = $1.strip
          if File.exist?(File.expand_path(path))
            images << { type: :file, path: File.expand_path(path) }
            "" # Remove from text
          else
            $&
          end
        end

        # Match image URLs
        cleaned.gsub!(/(https?:\/\/[^\s]+\.(?:png|jpg|jpeg|gif|webp|bmp)(?:\?[^\s]*)?)/i) do
          url = $1
          images << { type: :url, url: url }
          "" # Remove from text
        end

        [cleaned.strip, images]
      end

      # Returns true if the model_id matches a known vision-capable family.
      # Heuristic only — Configuration#model_supports_vision? lets callers
      # override per-tenant (e.g. behind a proxy where model_id is the literal
      # "auto" and the real upstream is decided server-side).
      def self.supports_vision?(model_id)
        model_id.match?(/gpt-4|claude|gemini|minimax-m3|mimo-v|qwen.*-vl|llava/i)
      end
    end
  end
end
