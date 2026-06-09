# frozen_string_literal: true

require_relative "../llm/content_builder"

module Rubino
  module Interaction
    # Parses a raw CLI input line and pulls out image attachments so they can
    # be routed to the model's native vision slot (image_paths) instead of being
    # sent as literal text.
    #
    # Three input shapes are recognised, mirroring how Claude Code lets a user
    # attach an image from the terminal:
    #
    #   1. `@path/to/pic.png` — the composer's `@` file-picker. When the picked
    #      file is an image it becomes an attachment; a non-image `@file` is left
    #      in the text untouched (the model reads it via the `read` tool, as
    #      before).
    #   2. A dropped / pasted file path — terminals insert an absolute path when
    #      a file is dragged in, often single/double-quoted or backslash-escaped
    #      for spaces. An image path (quoted, escaped or bare) is attached.
    #
    # Only paths that (a) have a recognised image extension AND (b) exist on disk
    # are attached; anything else is preserved verbatim in the returned text so
    # we never silently eat a word that merely looked path-ish.
    #
    # Returns a Result with the cleaned text (image tokens removed, whitespace
    # collapsed) and the de-duplicated, expanded absolute image paths in order.
    module ImageInput
      Result = Struct.new(:text, :image_paths, keyword_init: true) do
        def images? = !image_paths.empty?
      end

      # An `@token`: `@` followed by a run of non-space chars. Quoting inside an
      # `@` token isn't a terminal convention, so we keep it simple.
      AT_TOKEN = /(?<![^\s])@(\S+)/

      # A quoted path: '...' or "..." (drag-drop on terminals that quote).
      QUOTED_PATH = /(?<![^\s])(?:'([^']+)'|"([^"]+)")/

      # A bare / backslash-escaped path token: a leading /, ./, ../ or ~/ then a
      # run of non-space chars, allowing `\ ` escaped spaces (drag-drop default
      # on iTerm/Terminal.app). Anchored at a word boundary so it doesn't bite
      # into the middle of a URL or sentence.
      BARE_PATH = %r{(?<![^\s])((?:~|\.{0,2})/(?:\\.|\S)+)}

      module_function

      # Extracts image attachments from +input+. +existing+ lets a caller carry
      # forward images already attached to the pending turn (e.g. a clipboard
      # paste) so a follow-up line's parse adds to them rather than replacing.
      def parse(input, existing: [])
        text = input.to_s
        paths = []

        text = text.gsub(AT_TOKEN) { capture_if_image(Regexp.last_match(1), Regexp.last_match(0), paths) }
        text = text.gsub(QUOTED_PATH) do
          token = Regexp.last_match(1) || Regexp.last_match(2)
          capture_if_image(token, Regexp.last_match(0), paths)
        end
        text = text.gsub(BARE_PATH) { capture_if_image(Regexp.last_match(1), Regexp.last_match(0), paths) }

        Result.new(
          text: text.gsub(/[ \t]{2,}/, " ").strip,
          image_paths: (Array(existing) + paths).uniq
        )
      end

      # If +token+ resolves to an existing image file, record its absolute path
      # and drop it from the text (returns ""); otherwise leave the original
      # match (+original+) untouched. +original+ is captured by the caller before
      # any path work, because #expand runs its own gsub and would clobber
      # Regexp.last_match here.
      def capture_if_image(token, original, paths)
        path = expand(token)
        if LLM::ContentBuilder.image_file?(path) && File.file?(path)
          paths << path unless paths.include?(path)
          ""
        else
          original
        end
      end

      # Normalises a raw token into an absolute filesystem path: strips
      # backslash escapes (`\ ` → ` `) and expands `~`/relative paths.
      def expand(token)
        File.expand_path(token.to_s.gsub(/\\(.)/, '\1'))
      rescue ArgumentError
        token.to_s
      end
    end
  end
end
