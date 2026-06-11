# frozen_string_literal: true

require "pty"
require "io/console"
require "unicode/display_width"

# Scroll-boundary integration spec for the bottom composer. The reported bug:
# when streamed output reaches the LAST line of the terminal (so it SCROLLS) and
# the user had typed into the composer, the typed input was ERASED/duplicated on
# screen. Width math (@cols) was already hardened — this is the ROW behaviour at
# the scroll boundary.
#
# We drive the REAL composer inside a tiny PTY (a genuine TTY on both ends),
# capture the bytes it emits, and replay them through a faithful VT100 screen
# model that scrolls at the bottom row and honours the terminal's *deferred
# auto-wrap* ("pending wrap"): a glyph in the last column does not wrap until the
# next write, and a CRLF arriving while pending-wrap is set resolves as an EXTRA
# scroll. That last detail is what real terminals (xterm/VTE/Terminal.app) do
# and is exactly what desynced the live-region redraw before the fix. Asserting
# against the final rendered grid (not just the raw bytes) is what makes the
# test catch the on-screen desync.
#
# Skips gracefully when no PTY is available, per the no-manual-E2E rule.
RSpec.describe "BottomComposer scroll-boundary PTY" do
  # Minimal VT100 grid: CR, LF(+scroll at bottom), CUU(\e[<n>A), EL(\e[2K), and
  # DEC deferred auto-wrap. Faithful enough to expose live-region row desync.
  class VTGrid
    def initialize(rows, cols)
      @rows = rows
      @cols = cols
      @grid = Array.new(rows) { +" " * cols }
      @r = 0
      @c = 0
      @pending_wrap = false
    end

    def feed(bytes)
      s = bytes.dup.force_encoding(Encoding::UTF_8)
      i = 0
      while i < s.length
        ch = s[i]
        if ch == "\e" && s[i + 1] == "["
          j = i + 2
          j += 1 while j < s.length && s[j] =~ /[0-9;]/
          handle_csi(s[j], s[(i + 2)...j])
          i = j + 1
          next
        elsif ch == "\r"
          @c = 0
        elsif ch == "\n"
          # A CRLF arriving with pending-wrap set scrolls TWICE on real
          # terminals: the deferred wrap resolves into a scroll, then the LF
          # scrolls again. This is the boundary behaviour the fix must survive.
          newline if @pending_wrap
          @pending_wrap = false
          newline
        else
          putc(ch)
        end
        i += 1
      end
      self
    end

    def rows = @grid.map(&:rstrip)
    def bottom = @grid.last.rstrip

    private

    def handle_csi(final, params)
      case final
      when "A"
        n = params.to_i
        n = 1 if n.zero?
        @r = [@r - n, 0].max
        @pending_wrap = false
      when "K"
        @grid[@r] = +" " * @cols if params == "2"
      end
    end

    def putc(ch)
      if @pending_wrap
        newline
        @c = 0
        @pending_wrap = false
      end
      # A wide glyph (CJK/emoji) occupies TWO cells. If only one column remains it
      # cannot fit there: real terminals wrap it to the next row. Modelling this
      # is what lets the grid expose the char-count clamp bug (a "fits" clamp by
      # char count actually overflows the row in display columns and wraps).
      w = Unicode::DisplayWidth.of(ch)
      if w == 2 && @c == @cols - 1
        newline
        @c = 0
      end
      @grid[@r][@c] = ch
      last = @c + w - 1
      if last >= @cols - 1
        @pending_wrap = true # defer the wrap (DEC autowrap)
        @c = [@c + 1, @cols - 1].min
      else
        @c += w
      end
    end

    def newline
      if @r == @rows - 1
        @grid.shift
        @grid.push(+" " * @cols)
      else
        @r += 1
      end
    end
  end

  ROWS = 6
  COLS = 40
  PROMPT = Rubino::UI::BottomComposer::PROMPT

  def pty_available?
    PTY.open do |m, s|
      m.close
      s.close
    end
    true
  rescue StandardError
    false
  end

  # Runs +script+ (a String of Ruby) against a real composer inside a ROWS×COLS
  # PTY and returns the bytes the composer wrote. The script gets locals
  # +composer+ (started) and +queue+.
  def capture(script)
    require "tmpdir"
    harness = <<~RUBY
      $LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd))
      require "rubino"
      queue    = Rubino::Interaction::InputQueue.new
      composer = Rubino::UI::BottomComposer.new(input_queue: queue)
      composer.start
      #{script}
      $stdout.flush
      sleep 0.05
    RUBY
    file = File.join(Dir.tmpdir, "rubino_scroll_#{Process.pid}_#{rand(1e6).to_i}.rb")
    File.write(file, harness)
    out = (+"").force_encoding(Encoding::UTF_8)
    begin
      PTY.open do |master, slave|
        slave.winsize = [ROWS, COLS]
        pid = fork do
          master.close
          $stdin.reopen(slave)
          $stdout.reopen(slave)
          slave.close
          exec("ruby", file)
        end
        slave.close
        loop do
          chunk = master.read_nonblock(4096)
          out << chunk.force_encoding(Encoding::UTF_8)
        rescue IO::WaitReadable
          IO.select([master], nil, nil, 0.5) or break
          retry
        rescue Errno::EIO, EOFError
          break
        end
        Process.wait(pid)
      end
    ensure
      File.delete(file) if File.exist?(file)
    end
    out
  end

  before { skip "no PTY/TTY available in this environment" unless pty_available? }

  it "preserves the typed input on the bottom row when committed output scrolls" do
    raw = capture(<<~RUBY)
      "hello".each_char { |ch| composer.handle_key(ch) }
      8.times { |i| composer.print_above("line " + i.to_s) }
    RUBY
    grid = VTGrid.new(ROWS, COLS).feed(raw)
    # The input line survived the scroll: it sits on the bottom row, intact, and
    # appears exactly once anywhere on screen (not blanked, not duplicated).
    expect(grid.bottom).to eq("#{PROMPT}hello")
    prompt_rows = grid.rows.count { |r| r.include?("#{PROMPT}hello") }
    expect(prompt_rows).to eq(1)
  end

  # P3 rhythm blanks ride through the SAME erase→commit→redraw discipline:
  # an EMPTY committed line must scroll exactly ONE real blank row at the
  # bottom of the screen — never dropped (the pre-fix LiveRegion#commit
  # swallowed it), never doubled, and never desyncing the input row.
  it "scrolls one real blank row for an EMPTY commit at the scroll boundary" do
    raw = capture(<<~RUBY)
      "hello".each_char { |ch| composer.handle_key(ch) }
      6.times { |i| composer.print_above("line " + i.to_s) }
      composer.print_above("")
      composer.print_above("after")
    RUBY
    grid = VTGrid.new(ROWS, COLS).feed(raw)
    expect(grid.bottom).to eq("#{PROMPT}hello")
    expect(grid.rows.count { |r| r.include?("#{PROMPT}hello") }).to eq(1)
    # The blank committed between "line 5" and "after" occupies exactly one row.
    five  = grid.rows.index { |r| r.start_with?("line 5") }
    after = grid.rows.index { |r| r.start_with?("after") }
    expect(five).not_to be_nil
    expect(after).to eq(five + 2) # one blank row between, not zero, not two
    expect(grid.rows[five + 1].strip).to eq("")
  end

  it "preserves the typed input across a scroll while a FULL-WIDTH partial streams" do
    # A full-width streamed line is the real trigger: it writes the last column,
    # arming the terminal's deferred wrap; the following CRLF then double-scrolls
    # at the bottom and used to slide the live region out from under the redraw.
    raw = capture(<<~RUBY)
      "draft".each_char { |ch| composer.handle_key(ch) }
      6.times { |i| composer.print_above("filler " + i.to_s) }
      4.times { composer.set_partial("X" * 80) }
    RUBY
    grid = VTGrid.new(ROWS, COLS).feed(raw)
    expect(grid.bottom).to eq("#{PROMPT}draft")
    # Exactly one live partial row on screen (it updated in place, no per-token
    # stacked copies), and the prompt appears exactly once.
    partial_rows = grid.rows.count { |r| r.start_with?("…X") }
    expect(partial_rows).to eq(1)
    expect(grid.rows.count { |r| r.include?("#{PROMPT}draft") }).to eq(1)
  end

  it "does not accumulate stacked broken rows when a WIDE-GLYPH partial streams (table trail)" do
    # The streaming-table bug: each delta repaints the in-flight row, which is a
    # markdown table row carrying double-width emoji (✅ 🔄, display width 2). A
    # char-count clamp let the "clamped" row render WIDER than COLS, wrap to a
    # second physical line, and the single-row clear (\e[1A) left the overflow as
    # residue that stacked downward as a trail of leading-"…" broken lines.
    # With the display-width clamp the partial is always exactly one physical row,
    # so no trail accumulates. We stream several DIFFERENT wide rows like a table
    # filling in, then assert nothing piled up.
    raw = capture(<<~'RUBY')
      rows = [
        "| HTTP API ✅ | Done ✅ | High ⚠️ | Backend ✅ ok ✅",
        "| CLI Chat ✅ | Done ✅ | High ⚠️ | Frontend ✅ ok ✅",
        "| TUI Mode \U0001F504 | In Progress \U0001F504 | Medium ⚠️ ok \U0001F504",
        "| MCP Bridge \U0001F504 | In Progress \U0001F504 | Medium ⚠️ ok \U0001F504",
      ]
      rows.each { |r| composer.set_partial(r) }
    RUBY
    grid = VTGrid.new(ROWS, COLS).feed(raw)
    rows = grid.rows
    # Exactly ONE live partial row on screen — earlier ones were fully cleared,
    # none left a wrapped-overflow trail. (A trail would show >1 such row.)
    partial_rows = rows.count { |r| r.start_with?("…") }
    expect(partial_rows).to eq(1)
    # The prompt survives exactly once (no desync from an uncleared wrap). The
    # grid rstrips trailing spaces, so match the caret glyph, not "❯ ".
    expect(rows.count { |r| r.include?(PROMPT.rstrip) }).to eq(1)
    # Every rendered row fits within the terminal in DISPLAY columns (nothing
    # over-ran and wrapped).
    rows.each do |r|
      expect(Unicode::DisplayWidth.of(r)).to be <= COLS
    end
  end

  it "updates the partial in place WITHOUT scrolling when the prompt is not at the bottom" do
    # Non-scroll case: a fresh composer (prompt high on the screen). Growing the
    # partial must repaint one row in place and keep the prompt+buffer intact;
    # nothing should scroll a copy per token.
    raw = capture(<<~RUBY)
      "abc".each_char { |ch| composer.handle_key(ch) }
      %w[one onetwo onetwothree].each { |s| composer.set_partial(s) }
    RUBY
    grid = VTGrid.new(ROWS, COLS).feed(raw)
    rows = grid.rows
    # Prompt+buffer intact, exactly once (no scroll happened, so it stays put).
    expect(rows.count { |r| r == "#{PROMPT}abc" }).to eq(1)
    # The partial shows once (final value), in place — earlier values overwritten.
    expect(rows.count { |r| r == "onetwothree" }).to eq(1)
    expect(rows.count { |r| r.include?("one") }).to eq(1)
    # And the partial sits directly above the prompt row (the live-region layout).
    prompt_idx   = rows.index("#{PROMPT}abc")
    partial_idx  = rows.index("onetwothree")
    expect(partial_idx).to eq(prompt_idx - 1)
  end
end
