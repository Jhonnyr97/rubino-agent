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
    # Every candidate attachment is then gated through the SAME secure-by-default
    # attachment layer the server/run path uses (Attachments::Classify + Policy:
    # lstat/realpath safety pipeline, max_file_bytes cap, magic-byte kind check)
    # — the CLI used to bypass it entirely, shipping oversize/spoofed files to
    # the provider and burning the retry budget on the permanent error (#98).
    # A rejected candidate is consumed from the text and reported in
    # Result#rejected so the caller can surface a clean one-line error.
    #
    # Returns a Result with the cleaned text (image tokens removed, whitespace
    # collapsed), the de-duplicated, expanded absolute image paths in order, and
    # any policy rejections as { path:, reason: } hashes.
    module ImageInput
      Result = Struct.new(:text, :image_paths, :rejected, keyword_init: true) do
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
        rejected = []

        text = text.gsub(AT_TOKEN) { capture_if_image(Regexp.last_match(1), Regexp.last_match(0), paths, rejected) }
        text = text.gsub(QUOTED_PATH) do
          token = Regexp.last_match(1) || Regexp.last_match(2)
          capture_if_image(token, Regexp.last_match(0), paths, rejected)
        end
        text = text.gsub(BARE_PATH) { capture_if_image(Regexp.last_match(1), Regexp.last_match(0), paths, rejected) }

        Result.new(
          text: text.gsub(/[ \t]{2,}/, " ").strip,
          image_paths: (Array(existing) + paths).uniq,
          rejected: rejected.uniq
        )
      end

      # If +token+ resolves to an existing image file, record its absolute path
      # and drop it from the text (returns ""); otherwise leave the original
      # match (+original+) untouched. +original+ is captured by the caller before
      # any path work, because #expand runs its own gsub and would clobber
      # Regexp.last_match here. A candidate that LOOKS like an image but fails
      # the attachment policy is consumed too — never shipped, never left as a
      # path the model would chase with tools — and recorded in +rejected+.
      def capture_if_image(token, original, paths, rejected)
        path = expand(token)
        return original unless LLM::ContentBuilder.image_file?(path) && File.file?(path)

        if (reason = attachment_error(path))
          rejected << { path: path, reason: reason }
          ""
        else
          paths << path unless paths.include?(path)
          ""
        end
      end

      # Gates one candidate image through the universal attachment layer —
      # Attachments::Classify (lstat/realpath safety pipeline, max_file_bytes
      # cap, magic-byte classification) + Policy.allow_kind? — the SAME checks
      # the server/run path applies (#98). Returns a one-line human reason when
      # the file must NOT be attached, nil when it is safe to send.
      def attachment_error(path)
        cls = Attachments::Classify.call(path)
        unless cls.safe
          if cls.reason.to_s.start_with?("exceeds max_file_bytes")
            return "exceeds the #{Attachments::Policy.max_file_bytes / 1_048_576} MB attachment limit"
          end

          return cls.reason
        end
        return "not a valid image (content is #{cls.mime})" unless cls.kind == :image
        return "image attachments are disabled by policy (allow_kinds)" unless Attachments::Policy.allow_kind?(:image)

        nil
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
