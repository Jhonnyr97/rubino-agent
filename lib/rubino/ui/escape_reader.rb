# frozen_string_literal: true

module Rubino
  module UI
    # Reads and parses the byte tail of an ESC keystroke for the
    # {BottomComposer}: arrows / Home / End / Delete / word-jump / Shift+Tab /
    # Alt+Enter and the bracketed-paste body. PURE input: it only consumes
    # bytes from the keystroke source and returns a semantic action tuple —
    # the composer maps actions to its editing/menu/turn behavior, so all
    # rendering and state stay on its side of the seam.
    #
    # Three escape families are handled:
    #   * CSI  — ESC '[' params final  (arrows, Home/End, Delete, Shift+Tab,
    #            xterm modified keys like ESC[1;5C for Ctrl+→, bracketed paste)
    #   * SS3  — ESC 'O' final          (application-cursor arrows / Home/End)
    #   * Meta — ESC b / ESC f          (Alt+b / Alt+f word-jump on many terms)
    class EscapeReader
      # Bracketed paste (DEC 2004) end marker tail: the terminal closes a paste
      # with ESC[201~ (the opener ESC[200~ arrives as a normal CSI above).
      PASTE_END = "201~"

      # @param source [#call] returns the keystroke IO to read from. A callable
      #   rather than a captured IO so the reader always follows the composer's
      #   CURRENT input — the escape tail must come from the same stream the
      #   leading "\e" byte was read from, even if the IO is swapped (tests).
      def initialize(source)
        @source = source
      end

      # Consume the remainder of the escape sequence after a read "\e" and
      # return what it MEANS, as one of:
      #
      #   [:esc]                      lone ESC (no following bytes)
      #   [:alt_enter]                Alt/Meta+Enter (ESC CR / ESC LF)
      #   [:paste, body]              bracketed paste with its raw body
      #   [:mode_cycle]               Shift+Tab (ESC[Z)
      #   [:history_up] / [:history_down]      ↑ / ↓
      #   [:move_by, ±1]              bare ← / →
      #   [:word_left] / [:word_right]         modified ←/→, Alt+b/f
      #   [:move_home] / [:move_end]  Home / End (CSI, SS3 and tilde forms)
      #   [:delete_forward]           Delete (ESC[3~)
      #   nil                         unrecognized sequence (a quiet no-op)
      #
      # Non-blocking reads so a lone ESC doesn't hang.
      def read_action
        case read_nonblock_char
        when nil        then [:esc]
        when "\r", "\n" then [:alt_enter]
        when "["        then csi_action(read_csi)
        when "O"        then final_action(read_nonblock_char, modifier: 1)
        when "b"        then [:word_left]
        when "f"        then [:word_right]
        end
      end

      private

      # Acts on a parsed CSI sequence. Bracketed paste and Shift+Tab are
      # special; everything else splits into "params;…final" so a modified
      # arrow (ESC[1;5C = Ctrl+→) routes to the same move as the bare arrow
      # plus the modifier that promotes it to a word-jump.
      def csi_action(seq)
        case seq
        when "200~" then return [:paste, read_paste_body]
        when "Z"    then return [:mode_cycle] # Shift+Tab arrives as ESC[Z
        end

        final = seq[-1]
        params = seq[0...-1].split(";")
        # The modifier param is the 2nd field for xterm "1;mod<final>" form; the
        # numpad/edit keys (Home/End/Delete) carry "<n>;mod~". Default mod 1.
        modifier = (params[1] || params[0] || "1").to_i
        modifier = 1 if modifier.zero?
        if final == "~"
          tilde_action(params.first.to_i)
        else
          final_action(final, modifier: modifier)
        end
      end

      # Final-byte cursor keys (and SS3 arrows). A modifier > 1 (Ctrl=5, Alt=3,
      # Shift=2, etc.) promotes ←/→ to a word-jump, matching how terminals
      # encode Ctrl/Alt + arrow.
      def final_action(final, modifier:)
        word = modifier > 1
        case final
        when "A" then [:history_up]
        when "B" then [:history_down]
        when "C" then word ? [:word_right] : [:move_by, 1]
        when "D" then word ? [:word_left] : [:move_by, -1]
        when "H" then [:move_home]
        when "F" then [:move_end]
        end
      end

      # Tilde-terminated edit keys: 1/7 = Home, 4/8 = End, 3 = Delete-forward.
      def tilde_action(code)
        case code
        when 1, 7 then [:move_home]
        when 4, 8 then [:move_end]
        when 3    then [:delete_forward]
        end
      end

      # Reads the remainder of a CSI sequence: params (digits + ';') up to and
      # including the final byte in 0x40..0x7E. Returns the raw param/final
      # string, e.g. "A", "3~", "1;5C".
      def read_csi
        seq = +""
        loop do
          c = read_nonblock_char
          break if c.nil?

          seq << c
          break if c.ord.between?(0x40, 0x7E)
        end
        seq
      end

      # Accumulate a bracketed-paste body until the closing ESC[201~ marker.
      # Blocking reads here: a paste is a contiguous burst, so we won't hang
      # waiting on the user.
      def read_paste_body
        body = +""
        until body.end_with?(PASTE_END)
          c = read_paste_char
          break if c.nil?

          body << c
        end
        body = body[0...-PASTE_END.length] if body.end_with?(PASTE_END)
        # Drop the ESC[ that precedes the 201~ end marker.
        body.sub(/\e\[\z/, "")
      end

      # Blocking single-char read for the paste body (a paste arrives as one
      # uninterrupted burst).
      def read_paste_char
        input.getc
      rescue IOError, Errno::EIO # IOError covers EOFError
        nil
      end

      def read_nonblock_char
        input.read_nonblock(1)
      rescue IO::WaitReadable, IOError, Errno::EIO # IOError covers EOFError
        nil
      end

      def input
        @source.call
      end
    end
  end
end
