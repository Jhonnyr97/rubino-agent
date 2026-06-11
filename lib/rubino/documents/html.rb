# frozen_string_literal: true

require "kramdown"

module Rubino
  module Documents
    # The ONE HTML->Markdown core (markitdown's `HtmlConverter` / `markdownify`
    # equivalent). Every converter that can shape its content as HTML (the html
    # converter itself, and docx via a paragraphs->HTML step) feeds this. Built
    # on kramdown, which is ALREADY a rubino dependency, so no new lib is added.
    #
    # kramdown parses HTML and emits Markdown but defaults to reference-style
    # links ([text][1] + a [1]: url footer). LLMs read inline links more
    # naturally, so we post-process the reference definitions back inline. We
    # also strip non-content elements (script/style) before conversion.
    module Html
      module_function

      # Converts an HTML string to Markdown. Returns "" on failure rather than
      # raising -- the caller (to_markdown) treats empty as nil.
      def to_markdown(html)
        return "" if html.nil? || html.to_s.strip.empty?

        cleaned = strip_noise(html.to_s)
        md = Kramdown::Document.new(
          cleaned,
          input: "html",
          html_to_native: true
        ).to_kramdown
        inline_reference_links(md).strip
      rescue StandardError
        ""
      end

      # Removes script/style/head blocks (their text is not document content)
      # and the html/body document-wrapper tags, which kramdown otherwise leaves
      # as literal `<html>...</html>` lines around the converted body. What's
      # left is the inner content kramdown shapes into Markdown.
      def strip_noise(html)
        html
          .gsub(%r{<script\b[^>]*>.*?</script>}mi, "")
          .gsub(%r{<style\b[^>]*>.*?</style>}mi, "")
          .gsub(%r{<head\b[^>]*>.*?</head>}mi, "")
          .gsub(/<!--.*?-->/m, "")
          .gsub(%r{</?(?:html|body|!doctype)\b[^>]*>}mi, "")
      end

      # Rewrites kramdown's reference-style links/images back to inline form:
      #   [text][1] ... [1]: http://x  ->  [text](http://x)
      # Leaves the body untouched when there are no reference definitions.
      def inline_reference_links(markdown)
        defs = {}
        markdown.each_line do |line|
          m = line.match(/^\s*\[([^\]]+)\]:\s+(\S+)(?:\s+"[^"]*")?\s*$/)
          defs[m[1]] = m[2] if m
        end
        return markdown if defs.empty?

        body = markdown.gsub(/(!?)\[([^\]]*)\]\[([^\]]+)\]/) do
          bang = Regexp.last_match(1)
          text = Regexp.last_match(2)
          ref  = Regexp.last_match(3)
          url  = defs[ref.empty? ? text : ref]
          url ? "#{bang}[#{text}](#{url})" : Regexp.last_match(0)
        end
        # Drop the now-inlined reference-definition lines.
        body.each_line.grep_v(/^\s*\[[^\]]+\]:\s+\S+/).join
      end
    end
  end
end
