# frozen_string_literal: true

module Rubino
  module UI
    module Composer
      # The editable input line: the text buffer and the cursor, plus the pure
      # editing operations over them. NO terminal I/O, NO rendering, NO locking —
      # the composer owns the render mutex and calls these under it, then redraws.
      # Extracted from BottomComposer so the cursor/codepoint math lives in one
      # small, directly-unit-testable place instead of the god class.
      #
      # All indices are CODEPOINT offsets into +text+ (0..length). Mutators clamp
      # to the buffer and never raise on out-of-range input.
      class InputLine
        attr_reader :text, :cursor

        def initialize(text: +"", cursor: 0)
          @text   = text.to_s.dup
          @cursor = cursor.clamp(0, @text.length)
        end

        def length = @text.length
        def empty? = @text.empty?

        # Insert +str+ at the cursor and advance past it.
        def insert(str)
          chars = @text.chars
          chars.insert(@cursor, *str.to_s.chars)
          @text = chars.join
          @cursor += str.to_s.chars.length
          self
        end

        # Remove the single char BEFORE the cursor (Backspace). No-op at col 0.
        def delete_back
          return self unless @cursor.positive?

          chars = @text.chars
          chars.delete_at(@cursor - 1)
          @text = chars.join
          @cursor -= 1
          self
        end

        # Remove the char AT the cursor (Delete / Ctrl+D). No-op at end.
        def delete_forward
          chars = @text.chars
          if @cursor < chars.length
            chars.delete_at(@cursor)
            @text = chars.join
          end
          self
        end

        # Remove +len+ chars starting at codepoint +start+ and park the cursor at
        # +start+ — used to delete a whole "[Pasted text #N …]" placeholder token
        # in one keystroke (the span is computed by the caller from the store).
        def delete_span(start, len)
          chars = @text.chars
          chars.slice!(start, len)
          @text = chars.join
          @cursor = start
          self
        end

        # Delete from the cursor to the end of the line (Ctrl+K).
        def kill_to_end
          @text = @text.chars.first(@cursor).join
          self
        end

        # Clear the whole line (Ctrl+U on this single-line composer — see the
        # BottomComposer note on why this kills the whole line, not just to BOL).
        def clear
          @text = +""
          @cursor = 0
          self
        end

        # Replace the whole line and park the cursor at its end (history recall,
        # draft restore).
        def replace(str)
          @text = str.to_s.dup
          @cursor = @text.length
          self
        end

        # Move the cursor by +delta+ codepoints, clamped.
        def move_by(delta)
          @cursor = (@cursor + delta).clamp(0, @text.length)
          self
        end

        # Move the cursor to an absolute codepoint index, clamped.
        def move_to(index)
          @cursor = index.to_i.clamp(0, @text.length)
          self
        end

        # Word-jump LEFT: skip whitespace immediately left, then the word, landing
        # at the start of the previous word.
        def word_left
          chars = @text.chars
          i = @cursor
          i -= 1 while i.positive? && chars[i - 1] =~ /\s/
          i -= 1 while i.positive? && chars[i - 1] !~ /\s/
          @cursor = i
          self
        end

        # Word-jump RIGHT: skip the current word then trailing whitespace, landing
        # at the start of the next word.
        def word_right
          chars = @text.chars
          i = @cursor
          i += 1 while i < chars.length && chars[i] !~ /\s/
          i += 1 while i < chars.length && chars[i] =~ /\s/
          @cursor = i
          self
        end

        # Return the current text and reset to an empty line (submit).
        def take
          taken = @text
          clear
          taken
        end
      end
    end
  end
end
