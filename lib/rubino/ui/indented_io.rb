# frozen_string_literal: true

module Rubino
  module UI
    # Output decorator that left-pads everything written through it by a fixed
    # indent, so a TTY::Prompt menu renders in the SAME column as the card
    # above it (P7) instead of flush-left at column 0.
    #
    # tty-prompt repaints its frame by moving the cursor up, clearing lines,
    # and re-printing — so "start of line" is not only "after a newline": a
    # carriage return or a cursor column-reset escape (`\e[<n>G`) also restart
    # the line. The transform tracks that state ACROSS writes and injects the
    # indent before the first visible character of every line, leaving all
    # escape sequences untouched.
    #
    # Resolves the underlying IO from the given block on every call (default:
    # the current $stdout) so a composer/proxy swap can never strand a stale
    # handle. Everything else (tty?, winsize, …) delegates to that IO.
    class IndentedIO
      # ANSI CSI/OSC sequences pass through unindented; any other single
      # character is a candidate for the line-start indent.
      TOKEN_RE = /\e\[[\d;?]*[A-Za-z]|\e\][^\a\e]*(?:\a|\e\\)|./m

      def initialize(indent: "  ", io: nil)
        @indent        = indent
        @resolve       = io ? -> { io } : -> { $stdout }
        @at_line_start = true
      end

      def print(*args)
        io.print(*args.map { |a| transform(a.to_s) })
      end

      def write(*args)
        io.write(*args.map { |a| transform(a.to_s) })
      end

      def puts(*args)
        if args.empty?
          @at_line_start = true
          io.puts
        else
          print("#{args.join("\n")}\n")
        end
      end

      def <<(text)
        write(text)
        self
      end

      def flush
        io.flush
      end

      def method_missing(name, *, &)
        io.respond_to?(name) ? io.public_send(name, *, &) : super
      end

      def respond_to_missing?(name, include_private = false)
        io.respond_to?(name, include_private) || super
      end

      private

      def io
        @resolve.call
      end

      def transform(text)
        text.gsub(TOKEN_RE) do |tok|
          if ["\n", "\r"].include?(tok)
            @at_line_start = true
            tok
          elsif tok.start_with?("\e")
            @at_line_start = true if tok.match?(/\e\[\d*G\z/)
            tok
          elsif @at_line_start
            @at_line_start = false
            "#{@indent}#{tok}"
          else
            tok
          end
        end
      end
    end
  end
end
