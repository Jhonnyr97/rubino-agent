# frozen_string_literal: true

module Rubino
  module Util
    # OSC 8 terminal hyperlinks — wraps text in escape sequences that a
    # supporting terminal renders as clickable links.
    #
    # Sequence shape:  `\e]8;;URI\e\\LABEL\e]8;;\e\\`
    # The first `\e]8;;` opens the link, `\e\\` (String Terminator) ends
    # the URI segment, LABEL is what the user sees, and the trailing
    # `\e]8;;\e\\` closes the link.
    #
    # ## Support detection
    # OSC 8 is supported by iTerm2, WezTerm, vscode integrated terminal,
    # Hyper, Ghostty, and kitty. Apple_Terminal does NOT support it and
    # would render the escape codes as visible garbage. Detection is
    # CONSERVATIVE: unknown terminals default to off, so users on
    # Terminal.app or a tmux session whose outer terminal we can't
    # introspect never see junk in their scrollback.
    #
    # Override with `RUBINO_HYPERLINKS=1` to force on (useful in
    # tmux when you know the outer terminal supports OSC 8) or `=0` to
    # force off. `NO_COLOR=1` also forces off, matching the broader
    # convention used by every other ANSI-emitting tool in this CLI.
    #
    # ## Scope
    # OSC 8 lives ENTIRELY in the CLI adapter. The API adapter emits raw
    # structured events (tool name, arguments hash) and the web UI builds
    # its own `<a>` elements from that — terminal escape codes have no
    # business inside a JSON payload.
    module Hyperlink
      OPEN_PREFIX  = "\e]8;;"
      CLOSE_SUFFIX = "\e]8;;\e\\"
      ST           = "\e\\" # String Terminator

      # Terminals known to render OSC 8 correctly. Conservative list —
      # additions welcome as we confirm support elsewhere.
      KNOWN_TERM_PROGRAMS = %w[iTerm.app WezTerm vscode Hyper ghostty].freeze

      # True when the current terminal renders OSC 8 hyperlinks. Result is
      # cached per process because env vars don't change mid-run.
      def self.supported?
        return @supported if defined?(@supported)

        @supported = compute_support
      end

      # Test-only hook to reset the memoized support flag (specs flip env
      # vars between examples). Not part of the public contract.
      def self.reset!
        remove_instance_variable(:@supported) if defined?(@supported)
      end

      # Wraps LABEL in the OSC 8 sequence pointing to URI. Returns LABEL
      # unchanged when hyperlinks aren't supported, so callers can use the
      # result unconditionally — no escape codes leak into a Terminal.app
      # scrollback or an SSE payload.
      def self.wrap(label, uri:)
        return label.to_s if label.nil?
        return label.to_s unless supported?
        return label.to_s if uri.nil? || uri.to_s.empty?

        "#{OPEN_PREFIX}#{uri}#{ST}#{label}#{CLOSE_SUFFIX}"
      end

      # Builds a `file://` URI for the given path, expanding to absolute
      # so the terminal's URI handler doesn't try to resolve it against
      # its own cwd. Returns nil when the path is empty or doesn't exist
      # — callers should fall back to the raw label in that case.
      def self.file_uri(path)
        return nil if path.nil? || path.to_s.empty?

        abs = File.expand_path(path.to_s)
        return nil unless File.exist?(abs)

        "file://#{abs}"
      end

      # Convenience for the common case: "I have a file path, wrap it as
      # a clickable link to that file." Pass a different `label:` when
      # the displayed text differs from the path (e.g. truncated to fit
      # a header rule).
      def self.wrap_path(path, label: nil)
        uri  = file_uri(path)
        text = (label || path).to_s
        return text if uri.nil?

        wrap(text, uri: uri)
      end

      class << self
        private

        def compute_support
          return false if ENV["NO_COLOR"] && !ENV["NO_COLOR"].empty?
          return true  if ENV["RUBINO_HYPERLINKS"] == "1"
          return false if ENV["RUBINO_HYPERLINKS"] == "0"
          return true  if ENV["TERM"] == "xterm-kitty"

          KNOWN_TERM_PROGRAMS.include?(ENV.fetch("TERM_PROGRAM", nil))
        end
      end
    end
  end
end
