# frozen_string_literal: true

module Rubino
  module UI
    # Decodes a tool call's JSON arguments AS THEY STREAM into readable text, so
    # the timeline can show what a `write`/`edit`/`shell` is composing while the
    # model is still emitting it (#608). It surfaces the JSON string VALUES only
    # (the `content` a write is producing, the `command` a shell will run) and
    # drops the keys/structure, JSON-unescaping as it goes.
    #
    # #feed returns the COMPLETE decoded lines available so far (each ending in
    # "\n"), holding the partial last line back until its newline lands so the
    # caller never renders a half-line that the next fragment continues. #flush
    # returns whatever partial remains at the end of the call.
    #
    # Single pass, O(n): fragments are concatenated only across an incomplete
    # trailing escape (a "\\" or "\\uXXX" split mid-fragment), carried to the next
    # feed so an escape is never decoded half-formed.
    class ToolArgsStream
      # JSON single-char escapes → their literal char (\uXXXX is handled inline).
      UNESCAPE = { "n" => "\n", "t" => "\t", "r" => "\r", "b" => "\b",
                   "f" => "\f", '"' => '"', "\\" => "\\", "/" => "/" }.freeze

      def initialize
        @in_string  = false
        @is_value   = false      # the current string is a VALUE (emit) vs a KEY (skip)
        @containers = []         # stack of :obj / :arr to read `,` correctly
        @expect     = :value     # what the next opening string is (top-level value)
        @line       = +""        # decoded VALUE text not yet returned (current line)
        @carry      = +""        # raw chars held back across an incomplete escape
      end

      # Feed a raw argument fragment; returns the complete decoded lines unlocked
      # by it (possibly empty), with the partial last line held back.
      def feed(fragment)
        return "" if fragment.nil? || fragment.empty?

        scan(@carry + fragment)
        take_complete_lines
      end

      # Final partial line (the value tail with no trailing newline), or "".
      def flush
        out = @line.dup
        @line.clear
        out
      end

      # Non-destructive peek at the held partial line — used by repaint_in_progress
      # to re-emit the tool's in-progress params when focusing on a mid-stream
      # subagent, without consuming the partial and breaking the ongoing stream.
      def held_tail
        @line.dup
      end

      private

      # Walks chars, decoding string VALUES into @line. Stops early and stashes
      # an incomplete trailing escape into @carry so it is completed next feed.
      def scan(buf)
        @carry = +""
        i = 0
        n = buf.length
        while i < n
          ch = buf[i]
          if @in_string
            if ch == "\\"
              consumed = decode_escape(buf, i)
              return if consumed.nil? # incomplete escape → carried, wait for more

              i += consumed
              next
            elsif ch == '"'
              close_string
            elsif @is_value
              @line << ch
            end
          else
            structural(ch)
          end
          i += 1
        end
      end

      # Handles a backslash escape at buf[pos]. Returns the number of chars
      # consumed (>=2), or nil when the escape is split across the fragment
      # boundary (the raw tail is stashed in @carry to retry on the next feed).
      def decode_escape(buf, pos)
        nxt = buf[pos + 1]
        return carry(buf[pos..]) if nxt.nil?

        if nxt == "u"
          hex = buf[pos + 2, 4]
          return carry(buf[pos..]) if hex.nil? || hex.length < 4

          @line << [hex.to_i(16)].pack("U") if @is_value
          6
        else
          @line << UNESCAPE.fetch(nxt, nxt) if @is_value
          2
        end
      end

      # Stash the unfinished tail and signal "incomplete" to #scan.
      def carry(tail)
        @carry = tail.dup
        nil
      end

      def structural(chr)
        case chr
        when '"'
          @in_string = true
          @is_value  = (@expect == :value)
        when "{"
          @containers.push(:obj)
          @expect = :key
        when "["
          @containers.push(:arr)
          @expect = :value
        when "}", "]"
          @containers.pop
        when ":"
          @expect = :value
        when ","
          @expect = @containers.last == :arr ? :value : :key
        end
      end

      # A string just closed. After a VALUE, drop a newline so the next value
      # (e.g. a write's `content` after its `path`) starts on its own line.
      def close_string
        @in_string = false
        @line << "\n" if @is_value
        @expect = @containers.last == :arr ? :value : :key
      end

      # Splits @line at its last newline: everything up to and including it is
      # returned; the remainder stays buffered as the partial current line.
      def take_complete_lines
        idx = @line.rindex("\n")
        return "" if idx.nil?

        out = @line[0..idx]
        @line = @line[(idx + 1)..] || +""
        out
      end
    end
  end
end
