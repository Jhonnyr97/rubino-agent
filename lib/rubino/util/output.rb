# frozen_string_literal: true

module Rubino
  module Util
    # Smart truncation of long tool output for the scrollback preview.
    #
    # Rule shape (5 head + 10 tail + marker, threshold 30) follows the
    # pattern that emerged from surveying Codex, Gemini CLI, Roo, and
    # Aider: tail bias because errors, exit codes, and command summaries
    # live at the end. A head-heavy split (which would be intuitive for
    # "show me the start") consistently hides the part the user actually
    # needs when something failed.
    #
    # The FULL output still goes to the model and the session DB — this
    # is only what the user sees in the live scroll. The marker tells
    # them so they don't think they're missing something irrecoverable.
    module Output
      DEFAULT_MAX  = 30
      DEFAULT_HEAD = 5
      DEFAULT_TAIL = 10

      # The NUL byte (U+0000) is the one control char that is VALID UTF-8 yet
      # still breaks the persistence layer: the SQLite3 driver treats it as a
      # C-string terminator and raises "unrecognized token" (the tool row never
      # persists), and JSON re-tags the value as BINARY. String#scrub leaves it
      # alone (it only repairs INVALID bytes), so scrub-to-UTF-8 is necessary
      # but not sufficient — NUL has to go too.
      NUL = "\x00"

      # Coerces +text+ to a clean, persistable UTF-8 string: valid encoding AND
      # free of NUL bytes.
      #
      # Tool output is captured raw from a subprocess pipe / file read / MCP
      # response and can be binary or latin-1 (`head -c 1500 /dev/urandom`,
      # `cat some.png`). Such bytes are tagged UTF-8 (the pipe's external
      # encoding) but are NOT valid UTF-8, so the moment they reach
      # JSON.generate (the LLM request, the run-event store) or the SQLite
      # driver they raise "source sequence is illegal/malformed utf-8" /
      # "UTF-8 passed as BINARY" / "unrecognized token" and the tool row never
      # persists — the model loses the record on --resume. Random binary ALSO
      # carries NUL bytes, which survive String#scrub (NUL is valid UTF-8) yet
      # still wedge SQLite, so we strip them here too. Cleaning at the CAPTURE
      # seam (before the bytes are ever copied into the result) means every
      # downstream consumer sees a safe string. Idempotent on already-clean
      # input. Pure.
      def self.scrub_utf8(text)
        s = scrub_encoding(text)
        s.include?(NUL) ? s.delete(NUL) : s
      end

      # Encoding-only repair: returns a valid-UTF-8 string, leaving control
      # bytes (incl. NUL) in place. Split out from #scrub_utf8 because the two
      # consumers want different things downstream of "make it valid UTF-8":
      # the PERSIST seam (#scrub_utf8) deletes NUL outright (SQLite-fatal), but
      # the TERMINAL render seam (#sanitize_terminal) wants every control byte
      # turned into VISIBLE caret notation — so it scrubs encoding here, then
      # does its own C0/C1 pass instead of pre-deleting NUL. Pure.
      def self.scrub_encoding(text)
        s = text.to_s
        return s if s.encoding == Encoding::UTF_8 && s.valid_encoding?

        s.dup.force_encoding(Encoding::UTF_8).scrub
      end

      # ESC (0x1B): the introducer for ALL the dangerous sequences — CSI
      # (cursor move, screen clear, scroll region), OSC (set window title,
      # hyperlinks, clipboard write), DCS, etc.
      ESC = "\e"
      # U+009B is the single-byte CSI introducer: a terminal treats it exactly
      # like `ESC [`, so stripping ESC alone would leave a working injection
      # vector. It only exists AFTER UTF-8 decoding (the byte 0x9B on its own
      # is invalid UTF-8 and scrubbed; U+0085/U+0080–U+009F arrive via valid
      # 2-byte forms), so we strip the C1 block on the decoded string.
      C1_RANGE = "-"

      # Neutralizes terminal-control bytes in UNTRUSTED tool output before it
      # is printed to a real terminal.
      #
      # Threat (CWE-150): raw `\e[2J` (clear screen), `\e[41m…\e[0m` (color),
      # `\e]0;…\a` (set title), `\e]52;…` (clipboard write) embedded in
      # shell/file/MCP output reach the emulator and EXECUTE — the live tool
      # tail printed it verbatim. Following git's `core.fsmonitor`-style and
      # dgl.cx's "sanitize at the render chokepoint" guidance, we strip every
      # control byte that can move the cursor, repaint, or drive the terminal,
      # and render what we removed as visible caret/<XX> notation so the user
      # SEES that bytes were there (silent deletion hides the attack).
      #
      # Kept: \t (0x09) and \n (0x0A) — legitimate layout. \r is normalized to
      # \n (a bare CR rewinds the line and lets later text overwrite what was
      # already shown — another spoofing vector). Stripped: C0 0x00–0x1F
      # (except \t/\n), DEL 0x7F, ESC 0x1B, and the C1 block 0x80–0x9F.
      #
      # rubino's OWN styling (the @pastel.dim/green wrapper applied AROUND this
      # content) is a separate, trusted path and is never passed through here.
      # Pure.
      def self.sanitize_terminal(text)
        # Encoding-scrub ONLY (keep NUL et al.) so the C0 pass below can turn
        # every control byte into visible caret notation — silent deletion
        # would hide that the tool tried to emit them.
        s = scrub_encoding(text)
        # Bare CR (not part of CRLF) → newline, so overwrite-spoofing can't
        # rewind the rendered line. CRLF collapses to a single LF.
        s = s.gsub(/\r\n?/, "\n")
        s = s.gsub(/[\x00-\x08\x0B-\x1F\x7F]/) { |c| caret(c) }
        s.gsub(/[#{C1_RANGE}]/o) { |c| "<#{format("%02X", c.ord)}>" }
      end

      # Visible, unambiguous stand-in for a stripped control byte: ESC → "^[",
      # NUL → "^@", DEL → "^?" — the classic `cat -v` caret notation, so the
      # user can tell exactly what the tool tried to emit.
      def self.caret(byte)
        code = byte.ord
        return "^?" if code == 0x7F

        "^#{(code ^ 0x40).chr}"
      end

      # Returns either the full text (when total lines <= max) or a
      # head + marker + tail preview. Pure function — no side effects,
      # no IO. Caller decides where to render the result.
      #
      # @param text [String] the raw output
      # @param max  [Integer] line count above which we trim
      # @param head [Integer] lines to keep from the top
      # @param tail [Integer] lines to keep from the bottom
      # @return [String] the preview (always a String, never nil)
      def self.preview(text, max: DEFAULT_MAX, head: DEFAULT_HEAD, tail: DEFAULT_TAIL)
        return "" if text.nil? || text.to_s.empty?

        lines = text.to_s.lines.map(&:chomp)
        return lines.join("\n") if lines.size <= max

        omitted  = lines.size - head - tail
        head_pt  = lines.first(head)
        tail_pt  = lines.last(tail)
        marker   = "… [#{omitted} more lines · full in DB] …"

        (head_pt + [marker] + tail_pt).join("\n")
      end

      # Single-line elision to +max+ characters with a trailing ellipsis.
      # Shared by the parent-note tools (AnswerChild/Task/Steer) that all
      # carried a byte-identical private `truncate`. Pure function.
      #
      # @param text [#to_s] the raw text (nil becomes "")
      # @param max  [Integer] character budget before eliding
      # @return [String] the text, or its first +max+ chars + "…"
      def self.elide(text, max)
        s = text.to_s
        s.length > max ? "#{s[0, max]}…" : s
      end

      # First NON-BLANK line of +text+, stripped (or "" when all-blank). A
      # multi-line ruby/shell command often starts with a blank line, so a
      # naive `.lines.first` rendered an empty approval/activity hint (#141).
      # Pure function shared by the subagent card / view rows and the task
      # tool's approval preview, which each carried this extraction inline.
      def self.first_nonblank_line(text)
        text.to_s.each_line.map(&:strip).find { |l| !l.empty? }.to_s
      end

      # First NON-BLANK line, elided to +max+ chars (max-1 + "…"). The single
      # source for the subagent card and view rows, which carried a
      # byte-identical private copy. Distinct from #elide (which keeps +max+
      # chars before the ellipsis) — this row shape budgets the ellipsis IN.
      def self.first_line(text, max)
        first = first_nonblank_line(text)
        first.length > max ? "#{first[0, max - 1]}…" : first
      end

      # Truncates long tool output to stay within byte/line limits, with
      # tail-bias because the part the agent (and a human reading the log)
      # actually need is at the end: exit-code suffix, error message,
      # backtrace, "X failures" line. Head-only truncation drops exactly
      # the bytes that matter when something blows up at byte 49,999.
      #
      # Shape: keep ~10% head + bulk of the budget in the tail + a marker
      # in the middle saying how many bytes/lines were elided. Mirrors the
      # pattern #preview already uses for the scrollback body.
      #
      # When +spill+ is supplied it is called with the full pre-truncation
      # text and must return a path (or nil); the marker then points the
      # model at it, so the elided middle isn't lost — the model can `read`
      # the file with offset/limit to recover any part. (Claude-Code-style
      # spill.) Pure aside from that injected callback.
      def self.truncate(text, max_bytes:, max_lines:, spill: nil)
        # Scrub UNCONDITIONALLY at the tool→executor boundary. A stray
        # non-UTF-8 byte (printf '\xe9', xxd/grep over a latin-1 or binary
        # file) OR a NUL (random binary, `head -c … /dev/urandom`) in SUB-cap
        # output would otherwise pass straight through to JSON.generate and the
        # SQLite driver — raising "illegal/malformed utf-8" / "unrecognized
        # token", crashing the LLM request and leaving the tool row UNPERSISTED
        # so the model loses the record on --resume. scrub_utf8 fixes both
        # (invalid bytes + NUL). The truncation branches below only slice the
        # already-clean string, so cleaning once here covers every path.
        text = scrub_utf8(text)
        over_bytes = text.bytesize > max_bytes
        over_lines = text.lines.size > max_lines
        return text unless over_bytes || over_lines

        spill_path = spill&.call(text)
        text = tail_bias_bytes(text, max_bytes, spill_path) if over_bytes
        text = tail_bias_lines(text, max_lines, spill_path) if text.lines.size > max_lines
        text
      end

      def self.tail_bias_bytes(text, max_bytes, spill_path = nil)
        encoding        = text.encoding
        recover         = spill_path ? " · full output saved to #{spill_path} — read it with offset/limit" : ""
        marker_template = "\n... [%d bytes elided#{recover} · use grep/head to narrow] ...\n"
        marker_max      = (marker_template % 999_999_999).bytesize
        head_budget     = (max_bytes * 0.1).to_i
        tail_budget     = max_bytes - head_budget - marker_max

        # Below ~200 bytes the marker eats the entire budget, so fall back
        # to a simple head truncation (old behavior). Realistic caps go
        # through the head+tail path.
        if tail_budget <= 0
          truncated = text.byteslice(0, max_bytes).to_s.force_encoding(encoding).scrub("")
          tail_note = spill_path ? " · full output: #{spill_path}" : ""
          return "#{truncated}\n... [truncated at #{max_bytes} bytes#{tail_note}]"
        end

        head   = text.byteslice(0, head_budget).to_s.force_encoding(encoding).scrub("")
        tail   = text.byteslice(-tail_budget, tail_budget).to_s.force_encoding(encoding).scrub("")
        elided = text.bytesize - head.bytesize - tail.bytesize
        "#{head}#{format(marker_template, elided)}#{tail}"
      end

      def self.tail_bias_lines(text, max_lines, spill_path = nil)
        lines = text.lines
        return text if lines.size <= max_lines

        recover    = spill_path ? " · full output saved to #{spill_path} — read it with offset/limit" : ""
        head_count = [max_lines / 10, 5].max
        tail_count = max_lines - head_count - 1
        # Vanishing budget falls back to head-only truncation.
        if tail_count <= 0
          tail_note = spill_path ? " · full output: #{spill_path}" : ""
          return "#{lines.first(max_lines).join}\n... [truncated at #{max_lines} lines#{tail_note}]"
        end

        elided = lines.size - head_count - tail_count
        head   = lines.first(head_count).join
        tail   = lines.last(tail_count).join
        "#{head}... [#{elided} lines elided#{recover} · use grep/head to narrow] ...\n#{tail}"
      end
    end
  end
end
