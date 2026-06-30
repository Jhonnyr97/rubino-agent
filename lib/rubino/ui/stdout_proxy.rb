# frozen_string_literal: true

module Rubino
  module UI
    # An IO-shaped shim that routes everything written to it through a
    # {BottomComposer#print_above}, so the ~30 existing +$stdout.print/puts+ call
    # sites across UI::CLI / PrinterBase need ZERO changes. While a turn is
    # active, the chat command swaps +$stdout+ for one of these (prompt_toolkit's
    # +StdoutProxy+ model); on turn end it swaps the real IO back.
    #
    # Line buffering — the critical streaming nuance:
    #   UI::CLI#stream emits PARTIAL tokens with NO trailing newline during model
    #   streaming. A naive "print each write above the prompt" would scroll every
    #   token onto its own row. Instead we hold the in-progress line in
    #   +@partial+ and re-render it (the accumulating line) ABOVE the composer via
    #   {BottomComposer#set_partial} as it grows — a transient row redrawn in
    #   place — committing it to scrollback (via {BottomComposer#print_above})
    #   only when a newline arrives. The way prompt_toolkit buffers and batches:
    #   each newline-terminated segment becomes one committed row; the trailing
    #   partial keeps showing live.
    #
    # The render mutex lives in the composer, so concurrent writes from the
    # streaming thread and keystroke redraws stay serialized.
    class StdoutProxy
      # @param composer [BottomComposer] coordinator that owns print_above.
      def initialize(composer)
        @composer = composer
        @partial  = +""
      end

      # The two methods UI code actually uses are #print and #puts; #write backs
      # both formattings and is also what e.g. StringIO/IO duck-typers call.
      def write(*args)
        args.sum do |a|
          append(a.to_s)
          a.to_s.bytesize
        end
      end

      def print(*args)
        args.each { |a| append(a.to_s) }
        nil
      end

      def puts(*args)
        if args.empty?
          append("\n")
        else
          args.each do |a|
            if a.is_a?(Array)
              a.each { |e| puts(e) }
            else
              # Append the line and its terminating newline in ONE append so the
              # text commits straight to scrollback. Appending them separately
              # showed the line as a TRANSIENT partial row below the subagent
              # cards for a frame before the commit moved it above them — the
              # user saw the same line twice around the live card block (#153).
              s = a.to_s
              append(s.end_with?("\n") ? s : "#{s}\n")
            end
          end
        end
        nil
      end

      def printf(format, *)
        append(format(format, *))
        nil
      end

      def <<(obj)
        append(obj.to_s)
        self
      end

      # Streaming writers call flush after each token. We treat flush as "show
      # what you have now": re-render the accumulating partial line above the
      # composer so streamed text appears live, without committing it to
      # scrollback (it has no newline yet).
      def flush
        render_partial
        self
      end

      # REPLACE the live region with +str+ (replace, not accumulate). The normal
      # #append path GROWS @partial — right for token-by-token line buffering, but
      # wrong for the streaming-markdown tail, which is the WHOLE in-progress block
      # re-shown each time it changes. So we reset our own buffer and hand the raw
      # tail straight to the composer's transient row. Used by UI::CLI#stream to
      # show the incomplete block live while completed blocks commit above it.
      def live(str)
        @partial = +""
        @composer.set_partial(str.to_s)
        self
      end

      # Commit any held partial line as a final row. Called when the proxy is
      # torn down so an unterminated last line (e.g. a stream that ended without
      # stream_end) isn't lost.
      def finish
        return if @partial.empty?

        line = @partial
        @partial = +""
        @composer.print_above(line)
      end

      # Best-effort IO compatibility for code that probes the stream.
      def tty?   = false
      def isatty = false
      def sync   = true
      def fileno = nil

      # A faithful IO duck MUST answer #close: stdlib Logger::LogDevice treats a
      # logdev that responds to :write but NOT :close as a FILENAME and does
      # File.open(it) → "no implicit conversion of StdoutProxy into String" if a
      # Logger is ever built against $stdout while we hold the swap. No-op close.
      def close; end
      def closed? = false

      def sync=(_)
        true
      end

      private

      # Accumulate text, committing each complete (newline-terminated) line to
      # scrollback via print_above and keeping any trailing remainder as the live
      # partial. The partial is shown via #flush; many writers flush right after,
      # but we also render it here so a partial that arrives without a following
      # flush still appears.
      def append(str)
        return if str.nil? || str.empty?

        @partial << str
        committed = commit_complete_lines
        # print_above ALREADY cleared the partial row and repainted the prompt for
        # each line it committed; when nothing is left over, a second set_partial("")
        # would repaint the very same empty row — the double-frame-per-line that
        # helped wedge tmux during reasoning/tool streaming (#FREEZE). Only render
        # the partial when there's a non-empty remainder, or when no line committed
        # (a partial growing in place still needs its live row redrawn).
        render_partial unless committed && @partial.empty?
      end

      def commit_complete_lines
        nl = @partial.rindex("\n")
        return false unless nl

        # Commit the WHOLE run of finished lines in ONE frame. print_above →
        # LiveRegion#commit splits the embedded "\n" into CRLF-terminated rows
        # that each scroll into scrollback, so a 500-line tool result (a big
        # `read`, a long rendered markdown block) lands with a SINGLE live-region
        # clear+redraw instead of one full repaint PER line — the storm that
        # wedged tmux on "read many files / write file" (#FREEZE). Embedded "\r"
        # (the CLI's in-place clear before a streamed chunk) is preserved.
        # Strip ONLY the final "\n" (not a preceding "\r"): the per-line path this
        # replaces excluded just the newline and kept any in-place-clear "\r", and
        # LiveRegion#commit re-adds the row terminators.
        block = @partial[0...nl]
        @partial = @partial[(nl + 1)..] || +""
        @composer.print_above(block)
        true
      end

      # Show the in-progress (un-newlined) line above the composer without
      # committing it. set_partial renders it on a transient row directly above
      # the input line, redrawn in place — so the live partial grows in place as
      # tokens stream in rather than scrolling a copy per token. When the partial
      # is empty (just committed a line), clear the transient row.
      def render_partial
        @composer.set_partial(@partial)
      end
    end
  end
end
