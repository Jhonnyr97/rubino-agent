# frozen_string_literal: true

module Rubino
  module Documents
    module Converters
      # PPTX -> Markdown via the `ruby_powerpoint` gem (MIT, OPTIONAL). Each
      # slide becomes a `## Slide N` heading; the slide's text frames become
      # paragraphs/bullets and speaker notes go under a `>` block quote. The gem
      # gives us text per slide (and notes); it does not preserve shape geometry,
      # so we emit text in document order -- good enough for an LLM to read.
      class Pptx
        MIMES = %w[
          application/vnd.openxmlformats-officedocument.presentationml.presentation
        ].freeze

        def available?
          require "ruby_powerpoint"
          true
        rescue LoadError
          false
        end

        def accepts?(mime, path)
          return true if MIMES.include?(mime.to_s)

          File.extname(path.to_s).downcase == ".pptx"
        end

        def convert(path, budget = Limits.null_budget)
          require "ruby_powerpoint"
          # PRE-OPEN guard against a slide/text zip-expand bomb (see Docx).
          Limits.guard_zip!(path, budget, ["ppt/slides/*.xml", "ppt/notesSlides/*.xml"])
          ppt = RubyPowerpoint::Presentation.new(path)
          parts = ppt.slides.each_with_index.map do |slide, i|
            md = slide_markdown(slide, i + 1)
            budget.tick(bytes: md.to_s.bytesize)
            md
          end
          parts.compact.join("\n\n")
        end

        private

        def slide_markdown(slide, number)
          lines = ["## Slide #{number}"]

          title = slide.respond_to?(:title) ? slide.title.to_s.strip : ""
          lines << "### #{title}" unless title.empty?

          texts = Array(slide.respond_to?(:text) ? slide.text : nil)
                  .flatten
                  .map { |t| t.to_s.strip }
                  .reject { |t| t.empty? || t == title }
          texts.each { |t| lines << "- #{t}" }

          if slide.respond_to?(:notes)
            notes = slide.notes.to_s.strip
            lines << "\n> Notes: #{notes}" unless notes.empty?
          end

          return nil if lines.length == 1 # only the "## Slide N" header

          lines.join("\n")
        rescue StandardError
          nil
        end
      end
    end
  end
end
