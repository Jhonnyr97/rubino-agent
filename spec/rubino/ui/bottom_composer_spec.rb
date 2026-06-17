# frozen_string_literal: true

require "stringio"

# Unit specs for the bottom-pinned composer. These drive the composer directly
# (no live raw read / no PTY) by feeding keystrokes through #handle_key and
# capturing the ANSI it writes to an injected StringIO output. The PTY
# integration spec (bottom_composer_pty_spec.rb) exercises the real raw reader.
RSpec.describe Rubino::UI::BottomComposer do
  # StringIO that also answers #winsize (so the composer's width math is
  # deterministic without a real terminal).
  class FakeTermIO < StringIO
    def winsize = [24, 40]
  end

  subject(:composer) do
    described_class.new(input_queue: queue, input: input, output: output)
  end

  let(:queue)  { Rubino::Interaction::InputQueue.new }
  let(:output) { FakeTermIO.new }
  # A fake input that is "not a tty" so #start's cooked!/raw paths stay inert
  # when a test constructs but never starts.
  let(:input)  { StringIO.new }

  # Convenience: the prompt prefix the composer draws.
  PROMPT = Rubino::UI::BottomComposer::PROMPT

  describe ".active?" do
    it "is false when stdin is not a tty" do
      i = instance_double(IO, tty?: false)
      o = instance_double(IO, tty?: true)
      expect(described_class.active?(input: i, output: o)).to be(false)
    end

    it "is false when stdout is not a tty" do
      i = instance_double(IO, tty?: true)
      o = instance_double(IO, tty?: false)
      expect(described_class.active?(input: i, output: o)).to be(false)
    end

    it "is true only when both ends are ttys" do
      i = instance_double(IO, tty?: true)
      o = instance_double(IO, tty?: true)
      expect(described_class.active?(input: i, output: o)).to be(true)
    end
  end

  describe "#draw_input" do
    it "draws the prompt + buffer after a clear-line, with a trailing flush" do
      composer.handle_key("h")
      composer.handle_key("i")
      # Each keystroke redraws: assert the final frame draws "❯ hi".
      expect(output.string).to end_with("\r\e[2K#{PROMPT}hi")
    end

    it "WRAPS a buffer wider than the row onto a second visual row (no ellipsis)" do
      # Row budget = cols - 1 = 39; every row's text hangs at the prompt
      # width (P12), so each row holds 37 chars — the rest wraps to an
      # INDENTED continuation row below instead of the old single-row
      # scroll-window with its "…" elision.
      50.times { |i| composer.handle_key((97 + (i % 26)).chr) }
      typed = composer.buffer
      frame = output.string.split("\r\e[2K#{PROMPT}").last
      expect(frame).to start_with("#{typed[0, 37]}\r\n")
      expect(frame).to include("\r\e[2K  #{typed[37..]}")
      expect(frame).not_to include("…")
    end
  end

  # Rail rubino: the one-column red rail leads EVERY input row — the prompt
  # row and each wrapped/newline continuation — while committed echoes stay
  # rail-free in scrollback. All caret/wrap math re-anchors to the 3-column
  # "▍❯ " prefix; the ANSI color on the rail is invisible to the width math.
  describe "rail (Rail rubino)" do
    subject(:composer) do
      described_class.new(input_queue: queue, input: input, output: output,
                          rail: rail, echo: :prompt)
    end
    let(:rail) { "\e[31m▍\e[0m" } # pastel.red("▍"), as the chat command passes it

    it "draws the rail before the prompt on the input row" do
      composer.handle_key("h")
      composer.handle_key("i")
      expect(output.string).to end_with("\r\e[2K#{rail}#{PROMPT}hi")
    end

    it "draws the rail + hanging indent on every WRAPPED continuation row" do
      # Budget 39, prefix "▍❯ " = 3 cols → 36 chars on row 0, rest wraps.
      40.times { |i| composer.handle_key((97 + (i % 26)).chr) }
      typed = composer.buffer
      frame = output.string.split("\r\e[2K#{rail}#{PROMPT}").last
      expect(frame).to start_with("#{typed[0, 36]}\r\n")
      # Continuation: rail, then 2 spaces (hanging indent under the text start).
      expect(frame).to include("\r\e[2K#{rail}  #{typed[36..]}")
    end

    it "draws the rail on every REAL-newline continuation row too" do
      composer.send(:submit_paste, "line1\nline2\nline3")
      frame = output.string.split("\r\e[2K#{rail}#{PROMPT}").last
      expect(frame).to start_with("line1\r\n")
      expect(frame).to include("\r\e[2K#{rail}  line2")
      expect(frame).to include("\r\e[2K#{rail}  line3")
    end

    it "anchors the caret math to the rail+prompt prefix (Home → column 3)" do
      "abcdef".each_char { |c| composer.handle_key(c) }
      composer.handle_key("\x01") # Ctrl+A → line start
      # Park: re-home, then step right past the 3-col "▍❯ " prefix.
      expect(output.string).to end_with("\r\e[3C")
    end

    it "keeps the committed echo rail-free (no rail in scrollback)" do
      "hi".each_char { |c| composer.handle_key(c) }
      composer.handle_key("\r")
      # The committed echo row (freshly cleared, ends in CRLF) carries the
      # bare "❯ hi" — the rail never enters scrollback.
      expect(output.string).to include("\e[2K#{PROMPT}hi\r\n")
      expect(output.string).not_to include("#{rail}#{PROMPT}hi\r\n")
    end

    it "suspend clears the railed input rows (no leak into approval surfaces)" do
      orig_stdout = $stdout # suspend swaps $stdout to the composer's output
      allow(input).to receive(:tty?).and_return(false)
      composer.handle_key("x")
      composer.instance_variable_set(:@running, true)
      composer.suspend
      # Teardown order: bracketed paste OFF, then the erase of the railed
      # input row — the stream ENDS on the clear, so nothing re-draws the
      # rail over the suspended-composer surface (approval prompts).
      expect(output.string).to end_with("\e[?2004l\r\e[2K")
    ensure
      $stdout = orig_stdout
    end
  end

  # The streaming-table trail bug: a live partial row containing wide glyphs
  # (CJK/emoji, display width 2) must be clamped by DISPLAY columns, not char
  # count, or it renders wider than the row, wraps, and the single-row clear
  # leaves residue that accumulates downward.
  describe "#clamp (display-width aware)" do
    it "never exceeds the column budget in DISPLAY width for an emoji line" do
      # ✅ and 🔄 are width 2 but length 1. A 30-char emoji-laden line clamped to
      # 20 cols must occupy <= 20 display columns, not <= 20 chars.
      line = "| HTTP API ✅ | Done ✅ | High ⚠️ 🔄 done"
      clamped = composer.send(:clamp, line, 20)
      expect(composer.send(:display_width, clamped)).to be <= 20
    end

    it "left-truncates a wide line with a leading ellipsis" do
      line = "abcdefghij ✅ klmnopqrst ✅ uvwxyz ✅"
      clamped = composer.send(:clamp, line, 12)
      expect(clamped).to start_with("…")
      expect(composer.send(:display_width, clamped)).to be <= 12
    end

    it "drops a trailing wide glyph whole rather than splitting a cell" do
      # Budget of 1 column after the "…" cannot hold a width-2 glyph, so the
      # suffix must be empty (the glyph is dropped, never half-rendered).
      clamped = composer.send(:clamp, "abc✅", 2)
      expect(composer.send(:display_width, clamped)).to be <= 2
    end

    it "returns a short ASCII line unchanged (no regression)" do
      expect(composer.send(:clamp, "hello", 40)).to eq("hello")
    end

    it "flattens embedded newlines to spaces" do
      expect(composer.send(:clamp, "a\nb", 40)).to eq("a b")
    end

    # #426 (Bug A): the status ticker frame is coloured (dim ┄ track + red ◆ +
    # dim label, all wrapped in \e[…m SGR escapes). On a mid-stream resize its
    # STALE wide @partial was re-clamped at the new, narrower width; the
    # per-CHAR left-truncation walk measured each escape byte as a visible
    # column and could stop INSIDE a \e[2m run, dropping the leading \e and
    # leaking the literal "[2m" right after the "…" marker (the "…[2m" artifact
    # seen on screen). Clamp must treat each SGR escape as one atomic,
    # zero-width token so a left-truncation can never split one.
    it "never splits an ANSI escape on left-truncation (#426)" do
      e = "\e"
      track = (0...5).map { |c| c == 2 ? "#{e}[31m◆#{e}[0m" : "#{e}[2m┄#{e}[0m" }.join
      frame = "#{track} #{e}[2mthinking · 5s · ~7 tok · esc to interrupt#{e}[0m"
      # Clamp across every width that forces a left-truncation: not one of them
      # may leak a "[…m" literal whose leading \e was dropped.
      (1..composer.send(:display_width, frame)).each do |cols|
        clamped = composer.send(:clamp, frame, cols)
        # Every "[…m" present must still carry its leading ESC (a bare "[2m"
        # means the \e was cut off — the exact on-screen artifact).
        expect(clamped).not_to(match(/(?<!\e)\[[0-9;]+m/),
                               "cols=#{cols} leaked an orphaned SGR escape: #{clamped.inspect}")
      end
    end

    # ANSI SGR escapes occupy NO display columns, so a coloured frame measures
    # by its VISIBLE width — counting the escape bytes (each \e[2m is 4 chars)
    # made it measure ~2× wider and clamp a frame that actually fit (#426).
    it "measures display width ignoring zero-width ANSI escapes (#426)" do
      e = "\e"
      expect(composer.send(:display_width, "#{e}[2mhi#{e}[0m")).to eq(2)
    end
  end

  # TUI-2: a rendered INPUT row must fit ONE physical terminal line in DISPLAY
  # columns. The wrap math in #layout_input already breaks on display width,
  # but the drawn row is the defensive last line — a wide CJK/emoji glyph at a
  # boundary, or a degenerate narrow width where the prefix alone is wider than
  # the budget, must not leave a row at/over @cols that the terminal auto-wraps
  # onto a SECOND physical line the logical-row clear never erases (the ghost
  # "❯ …" rows that only Ctrl+L cleared). #fit_row right-truncates (whole-glyph,
  # ANSI-safe) to one column short of the width so logical rows == physical rows.
  describe "#fit_row (input-row width fit, TUI-2)" do
    # winsize is [24, 40] → @cols 40, so a fitted row is <= 39 display columns.
    it "fits a wide CJK row to one column short of the width" do
      row = "❯ #{"中" * 40}" # 80 display columns, far over a 40-col terminal
      fitted = composer.send(:fit_row, row)
      expect(composer.send(:display_width, fitted)).to be <= 39
    end

    it "drops a trailing wide glyph WHOLE rather than splitting a cell" do
      # At an odd remaining budget a width-2 glyph that would overflow is
      # dropped entire — the fitted width never lands on a half-cell.
      row = "x#{"中" * 30}"
      fitted = composer.send(:fit_row, row)
      expect(composer.send(:display_width, fitted)).to be <= 39
      # No mojibake: every kept char is whole (re-measuring is stable).
      flat = fitted.gsub(/\e\[[0-9;]*m/, "")
      expect(composer.send(:display_width, fitted)).to eq(flat.chars.sum { |c| Unicode::DisplayWidth.of(c) })
    end

    it "right-truncates (keeps the HEAD), unlike the ellipsis clamp" do
      row = ("a".."z").to_a.join * 3 # 78 ASCII columns
      fitted = composer.send(:fit_row, row)
      expect(fitted).to start_with("abcdefg") # the start the user typed is kept
      expect(fitted).not_to start_with("…") # not the left-truncation marker
    end

    it "leaves a row that already fits unchanged" do
      expect(composer.send(:fit_row, "❯ hello")).to eq("❯ hello")
    end

    it "never splits an ANSI escape while fitting a colored row" do
      e = "\e"
      row = "#{e}[31m▍#{e}[0m❯ " + ("界" * 40)
      fitted = composer.send(:fit_row, row)
      # Any SGR present still carries its leading ESC (no orphaned "[31m").
      expect(fitted).not_to(match(/(?<!\e)\[[0-9;]+m/))
      expect(composer.send(:display_width, fitted)).to be <= 39
    end
  end

  # TUI-2 (root): a long CJK buffer at a narrow width must wrap onto MULTIPLE
  # visual rows with NO drawn row exceeding the terminal — so the per-frame
  # input-block clear (which walks the LOGICAL row count) stays exact and no
  # ghost prompt rows accumulate in scrollback. The wrap path is display-width
  # aware end to end; this pins that every emitted row fits one physical line.
  describe "wide-char composer reflow (TUI-2)" do
    it "lays a long CJK buffer into rows that each fit one physical line" do
      ("中" * 60).each_char { |c| composer.handle_key(c) }
      rows, = composer.send(:visible_input_rows)
      cols = 40 # FakeTermIO winsize
      rows.each do |row|
        expect(composer.send(:display_width, row)).to be <= cols - 1
      end
    end

    it "keeps every drawn input row within the terminal for mixed CJK + ASCII" do
      "#{"测试很长的中文输入" * 3}ABCDEF".each_char { |c| composer.handle_key(c) }
      rows, = composer.send(:visible_input_rows)
      rows.each { |row| expect(composer.send(:display_width, row)).to be <= 39 }
    end
  end

  describe "buffer editing" do
    it "appends printable chars" do
      "abc".each_char { |c| composer.handle_key(c) }
      expect(composer.buffer).to eq("abc")
    end

    it "backspace removes the last char" do
      "abc".each_char { |c| composer.handle_key(c) }
      composer.handle_key("\b")
      expect(composer.buffer).to eq("ab")
    end

    it "DEL (\\177) also backspaces" do
      "abc".each_char { |c| composer.handle_key(c) }
      composer.handle_key("")
      expect(composer.buffer).to eq("ab")
    end

    it "backspace is codepoint-safe for multi-byte UTF-8" do
      composer.handle_key("a")
      composer.handle_key("é") # 2-byte codepoint
      composer.handle_key("中") # 3-byte codepoint
      expect(composer.buffer).to eq("aé中")
      composer.handle_key("\b")
      expect(composer.buffer).to eq("aé")
      composer.handle_key("\b")
      expect(composer.buffer).to eq("a")
    end

    # F9 — Ctrl+U clears the WHOLE line (not just to the start), so a half
    # typed command can't leave residual text that concatenates into the next.
    it "Ctrl+U clears the whole line, cursor at end of buffer" do
      "/memory".each_char { |c| composer.handle_key(c) }
      composer.handle_key("\x15") # Ctrl+U
      expect(composer.buffer).to eq("")
    end

    it "Ctrl+U clears even when the cursor is parked mid-line" do
      "hello world".each_char { |c| composer.handle_key(c) }
      composer.send(:move_to, 5) # cursor after "hello"
      composer.handle_key("\x15")
      expect(composer.buffer).to eq("")
    end

    # #395: Ctrl+L (\x0c) clears the screen + scrollback, homes the cursor, and
    # redraws the prompt in place — the readline/terminal norm. It must NOT
    # disturb the typed buffer (only the painted screen).
    it "Ctrl+L clears the screen and redraws the prompt, keeping the buffer" do
      "hello".each_char { |c| composer.handle_key(c) }
      output.truncate(0)
      output.rewind
      composer.handle_key("\x0c") # Ctrl+L
      # Emits the clear-screen + scrollback + home sequence...
      expect(output.string).to include("\e[2J\e[3J\e[H")
      # ...then redraws the prompt with the preserved buffer, untouched.
      expect(output.string).to end_with("#{PROMPT}hello")
      expect(composer.buffer).to eq("hello")
    end

    it "ignores stray control bytes" do
      composer.handle_key("a")
      composer.handle_key("") # Ctrl+A
      composer.handle_key("") # bell
      expect(composer.buffer).to eq("a")
    end
  end

  describe "#handle_key submit (Enter)" do
    it "pushes the line to the InputQueue and clears the buffer" do
      "hello".each_char { |c| composer.handle_key(c) }
      result = composer.handle_key("\r")
      expect(result).to eq(:submit)
      expect(queue.drain).to eq(["hello"])
      expect(composer.buffer).to eq("")
    end

    it "echoes the submitted line above the prompt (queued ▸ …)" do
      "ping".each_char { |c| composer.handle_key(c) }
      composer.handle_key("\n")
      expect(output.string).to include("queued ▸ ping")
    end

    it "drops a blank submit (only redraws, nothing queued)" do
      composer.handle_key("\r")
      expect(queue.drain).to eq([])
    end

    # echo: :prompt is the IDLE submit (the line IS the user's message): the
    # submitted line commits ABOVE the pinned prompt as "<prompt><line>", reading
    # back like a normal shell submit rather than the "queued ▸" steering marker.
    context "with echo: :prompt (idle path)" do
      subject(:composer) do
        described_class.new(input_queue: queue, input: input, output: output,
                            echo: :prompt)
      end

      it "echoes the submitted line above the prompt as <prompt><line>" do
        "hi".each_char { |c| composer.handle_key(c) }
        composer.handle_key("\r")
        expect(output.string).to include("❯ hi\r\n")
        expect(output.string).not_to include("queued ▸")
        expect(queue.drain).to eq(["hi"]) # still pushed for the REPL to consume
      end

      # D7: an idle (:prompt) submit is NEVER deferred — it's the user's actual
      # message, not a mid-stream type-ahead steer — so it commits immediately
      # even if (defensively) a stream flag were set. Idle echo is unchanged.
      it "commits the idle echo immediately even while content is streaming" do
        composer.begin_content_stream
        "hi".each_char { |c| composer.handle_key(c) }
        composer.handle_key("\r")
        expect(output.string).to include("❯ hi\r\n")
      end

      # #55: hammering Enter on an EMPTY idle buffer must be a FULL no-op for
      # scrollback — no committed "<prompt>" echo per tap (the old Reline path
      # stacked a bare prompt row each time), no queued line. The composer just
      # repaints its own row in place.
      it "swallows empty Enter spam with no committed prompt echo (#55)" do
        3.times { composer.handle_key("\r") }
        expect(queue.drain).to eq([])
        expect(output.string).not_to include("❯ \r\n")
      end

      it "swallows a whitespace-only submit the same way (#55)" do
        [" ", " ", "\r"].each { |ch| composer.handle_key(ch) }
        expect(queue.drain).to eq([])
        # No COMMITTED echo (a committed row ends in CRLF); the live
        # editing row legitimately shows the typed spaces before Enter.
        expect(output.string).not_to match(/❯ {2}\r\n/)
      end
    end

    # NEW MODEL (#421, Claude-Code type-ahead): Enter while a turn is active
    # QUEUES the line — it does NOT interrupt. The line is pushed to the queue
    # (FIFO) and shows a live "⏳ queued:" indicator above the input; the current
    # turn KEEPS RUNNING. No on_interrupt fires (Esc is the interrupt now). The
    # chat loop commits the line as a normal "<prompt><line>" message when its
    # turn runs (#commit_queued). The OLD "queued ▸" deferred echo stays retired.
    context "queue-by-default (Enter during an active turn)" do
      it "queues the line with a live indicator and does NOT interrupt, during streaming" do
        interrupts = 0
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> { interrupts += 1 })
        c.begin_turn
        c.begin_content_stream
        "ping".each_char { |ch| c.handle_key(ch) }
        c.handle_key("\r")
        expect(interrupts).to eq(0)            # the turn is NOT interrupted
        expect(queue.drain).to eq(["ping"])    # line parked for after the turn
        expect(output.string).not_to include("queued ▸") # old deferred echo retired
        # Visible while parked: the type-ahead line renders the same live
        # "⏳ queued:" row an explicit queue gets, removed at dequeue time.
        expect(output.string).to include("⏳ queued: ping")
        expect(c.commit_queued("ping")).to be(true) # dequeue clears it
      end

      it "queues during the THINKING phase too (turn active, not streaming)" do
        interrupts = 0
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> { interrupts += 1 })
        c.begin_turn # NO begin_content_stream yet (thinking)
        "while-thinking".each_char { |ch| c.handle_key(ch) }
        c.handle_key("\r")
        expect(interrupts).to eq(0)
        expect(queue.drain).to eq(["while-thinking"])
        expect(output.string).to include("⏳ queued: while-thinking")
        expect(output.string).not_to include("queued ▸")
      end

      # FIFO order: two lines typed during one turn stay in submission order, so
      # they run as their OWN turns A-then-B after the current one (no front-jump
      # — the old interrupt-by-default push_front is gone).
      it "stacks multiple Enter-queued lines in FIFO order" do
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> {})
        c.begin_turn
        c.begin_content_stream
        "msg A".each_char { |ch| c.handle_key(ch) }
        c.handle_key("\r")
        "msg B".each_char { |ch| c.handle_key(ch) }
        c.handle_key("\r")
        expect(queue.drain).to eq(["msg A", "msg B"]) # FIFO, A first
        idx_a = output.string.index("⏳ queued: msg A")
        idx_b = output.string.index("⏳ queued: msg B")
        expect(idx_a).to be < idx_b
      end

      # A queued Enter line never front-jumps an explicitly-parked item: an
      # Alt+Enter / "/queued" earlier in the turn keeps its place; the later
      # plain Enter lands BEHIND it.
      it "does not jump ahead of an earlier explicitly-queued item" do
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> {})
        c.begin_turn
        "/queued parked".each_char { |ch| c.handle_key(ch) }
        c.handle_key("\r")
        "typed".each_char { |ch| c.handle_key(ch) }
        c.handle_key("\r")
        expect(queue.drain).to eq(%w[parked typed]) # parked stays first
      end

      # end_turn is a quiet no-op for scrollback (no deferred echoes), but it
      # repaints to clear the affordance — assert it commits nothing new.
      it "commits nothing to scrollback at turn end (no deferred echoes)" do
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> {})
        c.begin_turn
        "x".each_char { |ch| c.handle_key(ch) }
        c.handle_key("\r")
        c.end_turn
        expect(output.string).not_to include("queued ▸ x")
      end
    end

    # Esc = INTERRUPT (#421): with a turn active, a lone Esc cancels the current
    # turn through the SAME on_interrupt hook (runner.cancel!). The chat loop
    # then runs the head of the queue; here we assert the composer FIRES the
    # interrupt (non-quiet) and does not arm the idle rewind chord.
    context "Esc interrupts the active turn (#421)" do
      def press_esc(c)
        # A lone ESC with no escape-sequence tail: feed an empty input so the
        # EscapeReader resolves :esc and routes to #handle_lone_esc.
        c.instance_variable_set(:@input, StringIO.new(""))
        c.handle_key("\e")
      end

      it "fires on_interrupt (non-quiet) while streaming" do
        quiet_values = []
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: ->(quiet = false) { quiet_values << quiet })
        c.begin_turn
        c.begin_content_stream
        press_esc(c)
        expect(quiet_values).to eq([false]) # interrupt fired exactly once, loud
      end

      it "fires during the THINKING phase and does NOT arm the idle rewind chord" do
        fired = 0
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> { fired += 1 })
        c.begin_turn # thinking, not streaming
        press_esc(c)
        expect(fired).to eq(1)
        # Mid-turn Esc interrupts; it never arms the Esc-Esc rewind chord.
        expect(c.instance_variable_get(:@last_esc_at)).to be_nil
      end

      it "interrupts and then the queue HEAD is what #shift returns (run next)" do
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> {})
        c.begin_turn
        c.begin_content_stream
        # Queue a line first (type-ahead), then interrupt with Esc.
        "msg B".each_char { |ch| c.handle_key(ch) }
        c.handle_key("\r")
        press_esc(c)
        expect(queue.shift).to eq("msg B") # the head runs immediately next
      end

      it "is a no-op (no interrupt) when idle (no turn active)" do
        fired = 0
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> { fired += 1 })
        # NO begin_turn: idle. Esc must NOT interrupt.
        press_esc(c)
        expect(fired).to eq(0)
      end

      it "still supports a no-arg interrupt hook (old contract)" do
        fired = 0
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> { fired += 1 })
        c.begin_turn
        press_esc(c)
        expect(fired).to eq(1)
      end
    end

    # H1 (CWE-150): a typed/pasted line carrying terminal control/escape
    # sequences must be NEUTRALIZED at the echo/commit render boundary — the
    # same defense the approval card already applies — so an OSC title-set
    # (\e]0;…\a) or CSI clear-screen (\e[2J) is rendered as inert caret notation
    # instead of EXECUTING against the terminal. Render-only: the model still
    # receives the literal text (it's pushed to the InputQueue raw).
    context "terminal-escape injection on submit/echo (CWE-150, H1)" do
      # Bytes only inserted via #insert reach the buffer; a typed lone ESC is
      # consumed as an escape sequence, so we drive the payload in as a paste —
      # exactly the real attack vector (pasting an untrusted string).
      def paste_into(c, text)
        c.send(:submit_paste, text)
      end

      it "neutralizes OSC/CSI escapes in the idle (:prompt) committed echo" do
        c = described_class.new(input_queue: queue, input: input, output: output,
                                echo: :prompt)
        paste_into(c, "\e]0;HIJACKED\ahi\e[2J")
        c.handle_key("\r")
        out = output.string
        expect(out).not_to include("\e]0;HIJACKED\a") # raw OSC title-set gone
        expect(out).not_to include("\e[2J")           # raw clear-screen gone
        expect(out).to include("^[]0;HIJACKED^G")     # shown inertly (caret)
        expect(out).to include("hi")                  # the real text survives
      end

      it "neutralizes escapes in the steering 'queued ▸' echo" do
        c = described_class.new(input_queue: queue, input: input, output: output)
        paste_into(c, "ping\e]0;PWN\a")
        c.handle_key("\r")
        out = output.string
        expect(out).to include("queued ▸ ping^[]0;PWN^G")
        expect(out).not_to include("\e]0;PWN\a")
      end

      it "still sends the LITERAL text to the model (sanitization is render-only)" do
        c = described_class.new(input_queue: queue, input: input, output: output,
                                echo: :prompt)
        paste_into(c, "\e]0;X\arun")
        c.handle_key("\r")
        # The pasted body is normalized at the buffer seam, so the queue carries
        # the neutralized-but-LOSSLESS rendering of the user's content (caret
        # notation), never the raw control bytes that would hijack the terminal.
        line = queue.drain.first
        expect(line).not_to include("\e") # no raw ESC reaches downstream
        expect(line).to include("run")
      end

      it "leaves plain / unicode / emoji echo unaffected" do
        c = described_class.new(input_queue: queue, input: input, output: output,
                                echo: :prompt)
        paste_into(c, "ciao 世界 🚀")
        c.handle_key("\r")
        expect(output.string).to include("❯ ciao 世界 🚀\r\n")
        expect(queue.drain).to eq(["ciao 世界 🚀"])
      end

      it "neutralizes escapes in the live input-block render (paste seam)" do
        c = described_class.new(input_queue: queue, input: input, output: output)
        paste_into(c, "\e]0;LIVE\a")
        # The buffer (what #draw_input renders AND what submit pushes) holds the
        # inert caret form, never the raw OSC bytes that would hijack the title.
        expect(c.buffer).to eq("^[]0;LIVE^G")
        expect(output.string).not_to include("\e]0;LIVE\a")
      end

      it "neutralizes escapes in the live '⏳ queued:' indicator row" do
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> {})
        c.begin_turn
        paste_into(c, "ping\e]0;PWN\a")
        c.handle_key("\r") # interrupt-by-default → live "⏳ queued:" indicator
        expect(output.string).to include("⏳ queued: ping^[]0;PWN^G")
        expect(output.string).not_to include("\e]0;PWN\a")
      end
    end

    # EXPLICIT QUEUE: Alt+Enter (\e\r) is now an ALIAS for plain Enter (queue is
    # the default, #421), and "/queued <msg>" the explicit prefix — both queue
    # WITHOUT interrupting (Esc interrupts). The queued message shows a live
    # "⏳ queued: <msg>" row above the input while pending; it's removed and
    # committed as a normal message when its turn runs (#commit_queued).
    context "explicit queue (Alt+Enter alias / /queued)" do
      it "Alt+Enter (\\e\\r) queues the buffer without firing on_interrupt" do
        interrupts = 0
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> { interrupts += 1 })
        c.begin_turn
        c.begin_content_stream
        "hold-this".each_char { |ch| c.handle_key(ch) }
        # Alt+Enter arrives as ESC then CR: preload the CR after ESC the way the
        # arrow/CSI specs drive escape sequences, then feed the ESC.
        c.instance_variable_set(:@input, StringIO.new("\r"))
        c.handle_key("\e")
        expect(interrupts).to eq(0)               # NOT interrupted
        expect(queue.drain).to eq(["hold-this"])  # queued
        expect(output.string).to include("⏳ queued: hold-this") # live indicator shown
        expect(c.buffer).to eq("") # buffer cleared
      end

      it "Alt+Enter via \\e\\n (LF form) also queues" do
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> {})
        c.begin_turn
        "lf-form".each_char { |ch| c.handle_key(ch) }
        c.instance_variable_set(:@input, StringIO.new("\n"))
        c.handle_key("\e")
        expect(queue.drain).to eq(["lf-form"])
        expect(output.string).to include("⏳ queued: lf-form")
      end

      it "/queued <msg> queues the message after the prefix without interrupting" do
        interrupts = 0
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> { interrupts += 1 })
        c.begin_turn
        c.begin_content_stream
        "/queued do this later".each_char { |ch| c.handle_key(ch) }
        c.handle_key("\r")
        expect(interrupts).to eq(0)
        expect(queue.drain).to eq(["do this later"]) # only the message, prefix stripped
        expect(output.string).to include("⏳ queued: do this later")
      end

      it "stacks multiple queued indicators in order and removes each on commit" do
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> {})
        c.begin_turn
        "/queued one".each_char { |ch| c.handle_key(ch) }
        c.handle_key("\r")
        "/queued two".each_char { |ch| c.handle_key(ch) }
        c.handle_key("\r")
        # Both shown, in order.
        idx_one = output.string.index("⏳ queued: one")
        idx_two = output.string.index("⏳ queued: two")
        expect(idx_one).not_to be_nil
        expect(idx_two).not_to be_nil
        expect(idx_one).to be < idx_two
        # Committing "one" removes only its row; "two" stays.
        expect(c.commit_queued("one")).to be(true)
        # The current frame no longer renders "one" but still renders "two".
        c.set_partial("") # force a fresh frame
        frame = output.string.split("\r\e[2K").last(8).join
        expect(frame).to include("⏳ queued: two")
        expect(frame).not_to include("⏳ queued: one")
      end

      # #130: at IDLE there is no turn whose completion could drain the queue —
      # Alt+Enter must behave exactly like plain Enter (parity with "/queued",
      # which runs immediately at idle), never park the line under a forever
      # "⏳ queued:" indicator.
      it "Alt+Enter at idle submits like plain Enter on the :prompt composer (#130)" do
        pending = []
        c = described_class.new(input_queue: queue, input: input, output: output,
                                echo: :prompt, pending_queued: pending)
        "what is 6+6?".each_char { |ch| c.handle_key(ch) }
        c.instance_variable_set(:@input, StringIO.new("\r"))
        c.handle_key("\e")

        expect(queue.drain).to eq(["what is 6+6?"])          # submitted, not parked
        expect(pending).to eq([])                            # no indicator left behind
        expect(output.string).to include("❯ what is 6+6?") # normal prompt echo
        expect(output.string).not_to include("⏳ queued")
      end

      it "Alt+Enter with no active turn on a :queued composer submits too (#130)" do
        interrupts = 0
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> { interrupts += 1 })
        # NO begin_turn: idle. Alt+Enter routes through the plain submit path.
        "idle chord".each_char { |ch| c.handle_key(ch) }
        c.instance_variable_set(:@input, StringIO.new("\r"))
        c.handle_key("\e")

        expect(interrupts).to eq(0)
        expect(queue.drain).to eq(["idle chord"])
        expect(output.string).not_to include("⏳ queued")
      end

      it "Alt+Enter mid-turn still queues (the idle parity does not regress queueing)" do
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> {})
        c.begin_turn
        "park me".each_char { |ch| c.handle_key(ch) }
        c.instance_variable_set(:@input, StringIO.new("\r"))
        c.handle_key("\e")
        expect(queue.drain).to eq(["park me"])
        expect(output.string).to include("⏳ queued: park me")
      end

      it "shares the pending list across composers (indicator survives teardown)" do
        pending = []
        c1 = described_class.new(input_queue: queue, input: input, output: output,
                                 on_interrupt: -> {}, pending_queued: pending)
        c1.begin_turn
        "/queued later".each_char { |ch| c1.handle_key(ch) }
        c1.handle_key("\r")
        expect(pending).to eq(["later"]) # recorded in the shared list
        # A fresh composer built on the same list still renders it.
        out2 = FakeTermIO.new
        c2 = described_class.new(input_queue: queue, input: input, output: out2,
                                 echo: :prompt, pending_queued: pending)
        c2.set_partial("") # force a frame
        expect(out2.string).to include("⏳ queued: later")
        expect(c2.commit_queued("later")).to be(true)
        expect(pending).to eq([]) # removed from the shared list
      end
    end

    # NO interrupt hook + no active turn: a :queued submit is unchanged —
    # immediate "queued ▸" echo (the standalone/legacy fallback).
    it "echoes a :queued submit immediately when no turn is active" do
      "ping".each_char { |c| composer.handle_key(c) }
      composer.handle_key("\r")
      expect(output.string).to include("queued ▸ ping")
    end
  end

  # BH-2: idle Ctrl+C must never silently discard a typed draft. A non-empty
  # buffer is CLEARED on the first Ctrl+C (no exit); an empty buffer arms a
  # transient "(press Ctrl+C again to exit)" hint and only a SECOND Ctrl+C
  # within the window exits.
  describe "#idle_interrupt (BH-2)" do
    it "clears a non-empty draft and stays (does NOT exit)" do
      "half typed".each_char { |c| composer.handle_key(c) }
      expect(composer.buffer).to eq("half typed")

      expect(composer.idle_interrupt(window: 2.0)).to eq(:cleared)
      expect(composer.buffer).to eq("") # draft cleared, not lost to an exit
    end

    it "clearing the draft also closes an open completion menu" do
      "/he".each_char { |c| composer.handle_key(c) } # opens the menu on a token
      composer.idle_interrupt(window: 2.0)
      expect(composer.menu_open?).to be(false)
      expect(composer.buffer).to eq("")
    end

    it "on an empty buffer the FIRST Ctrl+C hints and does NOT exit" do
      expect(composer.idle_interrupt(window: 2.0)).to eq(:hint)
      expect(output.string).to include("press Ctrl+C again to exit")
    end

    it "a SECOND empty Ctrl+C within the window exits" do
      expect(composer.idle_interrupt(window: 2.0)).to eq(:hint)
      expect(composer.idle_interrupt(window: 2.0)).to eq(:exit)
    end

    it "a slow second tap (outside the window) re-arms instead of exiting" do
      expect(composer.idle_interrupt(window: 0)).to eq(:hint)
      # window: 0 means the prior tap is already stale → a fresh hint, no exit.
      expect(composer.idle_interrupt(window: 0)).to eq(:hint)
    end

    it "clearing a draft resets the exit timer (no accidental exit next tap)" do
      expect(composer.idle_interrupt(window: 2.0)).to eq(:hint) # arm
      "oops".each_char { |c| composer.handle_key(c) }
      expect(composer.idle_interrupt(window: 2.0)).to eq(:cleared) # clears draft, resets
      expect(composer.idle_interrupt(window: 2.0)).to eq(:hint) # back to a fresh first tap
    end
  end

  # Slice 1: cursor-aware editing. The buffer is edited at an internal cursor
  # index, driven by arrows/Home/End/word-jump + insert/delete-at-cursor. Drive
  # the CSI sequences the way the paste/Shift+Tab specs do: preload the bytes
  # after ESC on the input IO, then call handle_key("\e").
  describe "cursor-aware editing" do
    def type(c, str)
      str.each_char { |ch| c.handle_key(ch) }
    end

    def cursor(c) = c.instance_variable_get(:@cursor)

    def esc_seq(c, bytes)
      c.instance_variable_set(:@input, StringIO.new(bytes))
      c.handle_key("\e")
    end

    it "inserts a typed char AT the cursor, not at the end" do
      type(composer, "abc")
      esc_seq(composer, "[D") # Left
      esc_seq(composer, "[D") # Left → cursor between a and b
      composer.handle_key("X")
      expect(composer.buffer).to eq("aXbc")
    end

    it "←/→ move the cursor and Home/End jump to the ends" do
      type(composer, "abcd")
      esc_seq(composer, "[D") # Left → 3
      expect(cursor(composer)).to eq(3)
      esc_seq(composer, "[C") # Right → 4
      expect(cursor(composer)).to eq(4)
      esc_seq(composer, "OH") # SS3 Home → 0
      expect(cursor(composer)).to eq(0)
      esc_seq(composer, "OF") # SS3 End → 4
      expect(cursor(composer)).to eq(4)
    end

    it "backspace deletes BEFORE the cursor mid-line" do
      type(composer, "abc")
      esc_seq(composer, "[D") # Left → between b and c
      composer.handle_key("\b") # delete b
      expect(composer.buffer).to eq("ac")
    end

    it "Delete key (ESC[3~) deletes AT the cursor (forward)" do
      type(composer, "abc")
      esc_seq(composer, "OH")  # Home → 0
      esc_seq(composer, "[3~") # Delete → removes 'a'
      expect(composer.buffer).to eq("bc")
    end

    it "Ctrl+D quits on an empty buffer and deletes forward otherwise" do
      expect(composer.handle_key("\x04")).to eq(:quit)
      type(composer, "ab")
      composer.handle_key("\x01") # Ctrl+A → start
      composer.handle_key("\x04") # delete 'a'
      expect(composer.buffer).to eq("b")
    end

    it "Ctrl+A / Ctrl+E / Ctrl+B / Ctrl+F move like emacs" do
      type(composer, "abc")
      composer.handle_key("\x01") # start
      expect(cursor(composer)).to eq(0)
      composer.handle_key("\x06") # forward
      expect(cursor(composer)).to eq(1)
      composer.handle_key("\x05") # end
      expect(cursor(composer)).to eq(3)
      composer.handle_key("\x02") # back
      expect(cursor(composer)).to eq(2)
    end

    it "Ctrl+K kills to end, Ctrl+U kills to start" do
      type(composer, "hello world")
      composer.handle_key("\x01")             # start
      5.times { composer.handle_key("\x06") } # → after "hello"
      composer.handle_key("\x0b")             # kill to end
      expect(composer.buffer).to eq("hello")
      composer.handle_key("\x15")             # kill to start
      expect(composer.buffer).to eq("")
    end

    it "word-jump left/right (ESC b / ESC f) lands on word boundaries" do
      type(composer, "alpha beta")
      esc_seq(composer, "b") # ESC b → start of "beta" (6)
      expect(cursor(composer)).to eq(6)
      esc_seq(composer, "b") # ESC b → start of "alpha" (0)
      expect(cursor(composer)).to eq(0)
      esc_seq(composer, "f") # ESC f → skip "alpha" + space → 6
      expect(cursor(composer)).to eq(6)
    end

    it "Ctrl+Left (ESC[1;5D) is a word-jump (modified arrow)" do
      type(composer, "one two")
      esc_seq(composer, "[1;5D") # Ctrl+Left → start of "two" (4)
      expect(cursor(composer)).to eq(4)
    end

    it "is multi-byte safe: cursor and delete count codepoints, not bytes" do
      type(composer, "aé中")
      esc_seq(composer, "[D")   # Left → between é and 中
      composer.handle_key("\b") # delete é
      expect(composer.buffer).to eq("a中")
    end
  end

  describe "↑/↓ history navigation" do
    subject(:composer) do
      described_class.new(input_queue: queue, input: input, output: output,
                          history: Rubino::UI::InputHistory.new(store: store))
    end

    let(:store) { [] }

    def arrow(c, final)
      c.instance_variable_set(:@input, StringIO.new("[#{final}"))
      c.handle_key("\e")
    end

    before do
      "first".each_char { |ch| composer.handle_key(ch) }
      composer.handle_key("\r")
      "second".each_char { |ch| composer.handle_key(ch) }
      composer.handle_key("\r")
    end

    it "↑ recalls the most recent entry, then older ones" do
      arrow(composer, "A")
      expect(composer.buffer).to eq("second")
      arrow(composer, "A")
      expect(composer.buffer).to eq("first")
    end

    it "↓ walks back toward the live draft" do
      "dr".each_char { |ch| composer.handle_key(ch) }
      arrow(composer, "A") # stashes "dr", shows "second"
      arrow(composer, "B") # back to the draft
      expect(composer.buffer).to eq("dr")
    end

    it "de-dups consecutive duplicate submits in history" do
      "second".each_char { |ch| composer.handle_key(ch) } # same as last
      composer.handle_key("\r")
      expect(store).to eq(%w[first second]) # not [first second second]
    end
  end

  describe "/command + @file completion menu" do
    subject(:composer) do
      described_class.new(input_queue: queue, input: input, output: output,
                          completion_source: source)
    end

    let(:source) do
      Rubino::UI::CompletionSource.new(commands: %w[/help /exit /reasoning /reset])
    end

    def tab(c) = c.handle_key("\t")

    def esc(c)
      c.instance_variable_set(:@input, StringIO.new("")) # lone ESC
      c.handle_key("\e")
    end

    def arrow(c, final)
      c.instance_variable_set(:@input, StringIO.new("[#{final}"))
      c.handle_key("\e")
    end

    it "shows a menu of matching slash commands as the token is typed" do
      "/re".each_char { |ch| composer.handle_key(ch) }
      expect(composer.menu_open?).to be(true)
      # The final frame (after the last \e[2K full-region clear) shows only the
      # matches for "/re" — /help has been filtered out.
      final_frame = output.string.split("\r\e[2K").last(4).join
      expect(final_frame).to include("/reasoning")
      expect(final_frame).to include("/reset")
      expect(final_frame).not_to include("/help")
    end

    # Reline parity: the dropdown appears AUTOMATICALLY as the user types a
    # leading `/`/`@` token — no Tab needed. (Replaces the old "Tab-only, typing
    # doesn't auto-open" contract.)
    it "auto-opens populated with ALL slash commands when a bare / is typed" do
      composer.handle_key("/")
      expect(composer.menu_open?).to be(true)
      expect(output.string).to include("/help")
      expect(output.string).to include("/exit")
      expect(output.string).to include("/reasoning")
      expect(output.string).to include("/reset")
    end

    it "auto-filters as the token grows (no Tab)" do
      "/re".each_char { |ch| composer.handle_key(ch) }
      expect(composer.menu_open?).to be(true)
      expect(output.string).to include("/reasoning")
      expect(output.string).to include("/reset")
    end

    it "auto-closes when the token stops matching, and when a trailing space ends it" do
      "/re".each_char { |ch| composer.handle_key(ch) }
      expect(composer.menu_open?).to be(true)
      composer.handle_key("z") # "/rez" → no candidates
      expect(composer.menu_open?).to be(false)
      composer.handle_key("\b") # back to "/re" → reopens (a fresh, un-dismissed token)
      expect(composer.menu_open?).to be(true)
      composer.handle_key(" ")  # trailing space ends the token
      expect(composer.menu_open?).to be(false)
    end

    it "Tab accepts the highlighted candidate (token replaced + trailing space)" do
      "/re".each_char { |ch| composer.handle_key(ch) } # menu auto-opens
      tab(composer) # accept the first (/reasoning)
      expect(composer.buffer).to eq("/reasoning ")
      expect(composer.menu_open?).to be(false)
    end

    # F9 — accepting a completion while the cursor sits MID-token must replace
    # the WHOLE token, not concatenate the un-measured tail (`/reasoningasoning`,
    # the `/memorymemory` class of bug). The accept swallows the trailing run.
    it "accepting mid-token replaces the whole token (no residual concat)" do
      "/reasoning".each_char { |ch| composer.handle_key(ch) }
      composer.send(:move_to, 3) # cursor at "/re|asoning"; menu re-opens for /re
      expect(composer.menu_open?).to be(true)
      tab(composer) # accept /reasoning
      expect(composer.buffer).to eq("/reasoning ")
      expect(composer.menu_open?).to be(false)
    end

    it "↓ then Enter accepts the SECOND candidate" do
      "/re".each_char { |ch| composer.handle_key(ch) } # menu auto-opens
      arrow(composer, "B") # ↓ → /reset
      composer.handle_key("\r")
      expect(composer.buffer).to eq("/reset ")
      expect(composer.menu_open?).to be(false)
    end

    it "Esc dismisses the menu IMMEDIATELY leaving exactly what was typed (D6)" do
      "/re".each_char { |ch| composer.handle_key(ch) } # menu auto-opens
      expect(composer.menu_open?).to be(true)
      esc(composer)
      expect(composer.menu_open?).to be(false)
      expect(composer.buffer).to eq("/re") # no fused candidate, no fragment
    end

    it "Esc STICKS: the menu stays closed while the same token is typed further" do
      composer.handle_key("/") # auto-opens
      expect(composer.menu_open?).to be(true)
      esc(composer)
      expect(composer.menu_open?).to be(false)
      "re".each_char { |ch| composer.handle_key(ch) } # still the same /-token
      expect(composer.menu_open?).to be(false) # dismiss stuck — no pop-back
    end

    it "after Esc, clearing the token (or Tab) lets the menu open again" do
      "/re".each_char { |ch| composer.handle_key(ch) }
      esc(composer)
      expect(composer.menu_open?).to be(false)
      # Backspace down to nothing clears the token → suppression lifts.
      3.times { composer.handle_key("\b") }
      expect(composer.buffer).to eq("")
      composer.handle_key("/") # a fresh token auto-opens
      expect(composer.menu_open?).to be(true)
      esc(composer)
      expect(composer.menu_open?).to be(false)
      tab(composer) # an explicit Tab reopens even while suppressed
      expect(composer.menu_open?).to be(true)
    end

    it "auto-opens the @file picker as you type, and filters (no Tab)" do
      src = Rubino::UI::CompletionSource.new
      files = %w[@lib/a.rb @src/b.rb]
      # Filter by prefix like the real source does, so every intermediate token
      # ("@", "@s", "@sr", "@src") returns the right slice as we type.
      allow(src).to receive(:candidates_for) do |token|
        files.select { |f| f.downcase.start_with?(token.downcase) }
      end
      c = described_class.new(input_queue: queue, input: input, output: output,
                              completion_source: src)
      c.handle_key("@")
      expect(c.menu_open?).to be(true)
      expect(output.string).to include("@lib/a.rb")
      "src".each_char { |ch| c.handle_key(ch) }
      expect(c.menu_open?).to be(true)
      expect(c.instance_variable_get(:@menu).items).to eq(%w[@src/b.rb])
    end

    it "closes the menu when the cursor moves off the token" do
      "/re".each_char { |ch| composer.handle_key(ch) }
      expect(composer.menu_open?).to be(true)
      composer.handle_key("\x01") # Ctrl+A → cursor to line start, off the token
      expect(composer.menu_open?).to be(false)
    end

    it "dismiss-then-retype-then-submit is clean (the classic D6 corruption case)" do
      "/re".each_char { |ch| composer.handle_key(ch) } # menu auto-opens
      esc(composer)                                    # dismissed (sticks)
      "set".each_char { |ch| composer.handle_key(ch) } # "/reset" (stays closed)
      composer.handle_key("\r")
      expect(queue.drain).to eq(["/reset"])
    end

    it "re-filters the open menu as more of the token is typed" do
      "/r".each_char { |ch| composer.handle_key(ch) } # menu auto-opens: /reasoning /reset
      "ea".each_char { |ch| composer.handle_key(ch) } # "/rea" → only /reasoning
      expect(composer.menu_open?).to be(true)
    end

    it "closes the menu when the token stops matching anything" do
      "/re".each_char { |ch| composer.handle_key(ch) } # menu auto-opens
      composer.handle_key("z") # "/rez" → no candidates
      expect(composer.menu_open?).to be(false)
      expect(composer.buffer).to eq("/rez") # buffer intact
    end

    it "Tab on non-completable text is a no-op (no literal tab inserted)" do
      "hello".each_char { |ch| composer.handle_key(ch) }
      tab(composer)
      expect(composer.menu_open?).to be(false)
      expect(composer.buffer).to eq("hello")
    end

    # D5: when the typed token is ALREADY an exact, complete command (the only /
    # selected candidate), Enter SUBMITS it instead of splicing a trailing space
    # and forcing a second Enter.
    describe "Enter on an exact full command (D5)" do
      let(:source) do
        Rubino::UI::CompletionSource.new(commands: %w[/new /help /reasoning /reset])
      end

      it "submits immediately when the buffer is exactly a command (sole candidate)" do
        "/new".each_char { |ch| composer.handle_key(ch) } # menu auto-opens, only /new
        expect(composer.menu_open?).to be(true)
        result = composer.handle_key("\r")
        expect(result).to eq(:submit)
        expect(queue.drain).to eq(["/new"]) # submitted, NOT "/new " then a 2nd Enter
        expect(composer.buffer).to eq("")
      end

      it "submits an exact command even when other commands share its prefix, if it's selected" do
        # "/re" is ambiguous (/reasoning, /reset) → Enter accepts the highlight.
        "/re".each_char { |ch| composer.handle_key(ch) }
        composer.handle_key("\r")
        expect(composer.buffer).to eq("/reasoning ") # accept-highlight, NOT submit
        expect(queue.drain).to eq([])
      end

      it "still accepts the highlighted candidate for a partial token (Enter)" do
        "/res".each_char { |ch| composer.handle_key(ch) } # only /reset matches but not exact
        composer.handle_key("\r")
        expect(composer.buffer).to eq("/reset ")
        expect(queue.drain).to eq([])
      end

      it "Tab-accept is unchanged for an exact command (splice + trailing space)" do
        "/new".each_char { |ch| composer.handle_key(ch) }
        tab(composer)
        expect(composer.buffer).to eq("/new ")
        expect(composer.menu_open?).to be(false)
      end
    end

    # #147: the approval hint says "/agents sa_xxx to approve". Typing exactly
    # that pops the argument dropdown (the id, then the verb grammar), and
    # Enter used to be swallowed by it — the exact command the hint dictated
    # did nothing. Enter with the buffer already a complete valid command must
    # SUBMIT; accepting stays for partial tokens and arrow-navigated picks.
    describe "Enter on a complete command with the argument dropdown open (#147)" do
      let(:source) do
        Rubino::UI::CompletionSource.new(
          commands: %w[/agents /help],
          arg_sources: { "agents" => lambda { |args|
            case args.length
            when 0 then %w[sa_1855c6ef]
            when 1 then ["steer", "probe", "--stop"]
            else []
            end
          } }
        )
      end

      it "submits a fully-typed `/agents <id>` even with the id dropdown open" do
        "/agents sa_1855c6ef".each_char { |ch| composer.handle_key(ch) }
        expect(composer.menu_open?).to be(true) # the dropdown is up — the trap
        result = composer.handle_key("\r")
        expect(result).to eq(:submit)
        expect(queue.drain).to eq(["/agents sa_1855c6ef"])
      end

      it "submits when the verb dropdown is open on an EMPTY argument (`/agents <id> `)" do
        "/agents sa_1855c6ef ".each_char { |ch| composer.handle_key(ch) }
        expect(composer.menu_open?).to be(true) # steer/probe/--stop showing
        result = composer.handle_key("\r")
        expect(result).to eq(:submit) # NOT a spliced "steer " the user never typed
        expect(queue.drain).to eq(["/agents sa_1855c6ef "])
      end

      it "still accepts on Enter when the user arrow-navigated onto a verb" do
        "/agents sa_1855c6ef ".each_char { |ch| composer.handle_key(ch) }
        arrow(composer, "B") # ↓ → probe (explicit accept intent)
        composer.handle_key("\r")
        expect(composer.buffer).to eq("/agents sa_1855c6ef probe ")
        expect(queue.drain).to eq([])
      end

      it "still accepts on Enter for a partial argument token" do
        "/agents sa_1855c6ef st".each_char { |ch| composer.handle_key(ch) }
        expect(composer.menu_open?).to be(true) # "st" → steer
        composer.handle_key("\r")
        expect(composer.buffer).to eq("/agents sa_1855c6ef steer ")
        expect(queue.drain).to eq([])
      end
    end

    # The SAME dropdown picks the ARGUMENT of /skills (a skill name), reusing the
    # menu/accept plumbing — not a new widget. The CompletionSource resolves the
    # argument via its registered arg_sources entry.
    describe "/skills argument completion (skill picker)" do
      let(:source) do
        Rubino::UI::CompletionSource.new(
          commands: %w[/skills /help],
          arg_sources: { "skills" => -> { %w[ruby-expert react-pro] } }
        )
      end

      it "auto-opens the SAME menu on the argument once '/skills ' is typed" do
        "/skills".each_char { |ch| composer.handle_key(ch) }
        # While typing the command itself the command menu shows /skills.
        expect(composer.menu_open?).to be(true)
        composer.handle_key(" ") # cross into the argument position
        expect(composer.menu_open?).to be(true)
        frame = output.string
        expect(frame).to include("ruby-expert")
        expect(frame).to include("react-pro")
        expect(frame).to include("✗ none")
      end

      it "filters skill names as the argument partial grows" do
        "/skills re".each_char { |ch| composer.handle_key(ch) }
        expect(composer.menu_open?).to be(true)
        frame = output.string.split("\r\e[2K").last(5).join
        expect(frame).to include("react-pro")
        expect(frame).not_to include("ruby-expert")
      end

      it "Tab accepts the skill name into the argument (splice + trailing space)" do
        "/skills ru".each_char { |ch| composer.handle_key(ch) }
        tab(composer)
        expect(composer.buffer).to eq("/skills ruby-expert ")
        expect(composer.menu_open?).to be(false)
      end

      it "↓+Enter selects a skill name and submits /skills <name>" do
        "/skills ".each_char { |ch| composer.handle_key(ch) }
        # Items: ["✗ none", "ruby-expert", "react-pro"]. ↓ → ruby-expert.
        arrow(composer, "B")
        composer.handle_key("\r") # accept (not an exact command)
        expect(composer.buffer).to eq("/skills ruby-expert ")
        composer.handle_key("\r") # submit (trailing accept-space preserved, as /command does)
        expect(queue.drain).to eq(["/skills ruby-expert "])
      end

      # #63: accepting a command name lands the cursor in its ARGUMENT
      # position — the next context's dropdown must open IMMEDIATELY, not one
      # keystroke late (accept used to clear the menu and never re-run the
      # refresh for the new context).
      it "auto-opens the argument dropdown right after Tab-accepting /skills (#63)" do
        "/skil".each_char { |ch| composer.handle_key(ch) }
        tab(composer)
        expect(composer.buffer).to eq("/skills ")
        expect(composer.menu_open?).to be(true)
        expect(output.string).to include("ruby-expert")
      end

      it "stays closed after accepting a command with no argument source (#63)" do
        "/hel".each_char { |ch| composer.handle_key(ch) }
        tab(composer)
        expect(composer.buffer).to eq("/help ")
        expect(composer.menu_open?).to be(false)
      end
    end

    # #39: the dropdown shows each command's one-line description (the same
    # strings /help carries) next to its name, and surfaces the /agents
    # subcommand grammar (id → steer/probe/--stop) as completions.
    describe "descriptions + /agents subcommand grammar (#39)" do
      let(:source) do
        Rubino::UI::CompletionSource.new(
          commands: %w[/agents /help],
          arg_sources: { "agents" => lambda { |args|
            args.empty? ? %w[sa_aaaa] : ["steer", "probe", "--stop"]
          } },
          descriptions: { "/help" => "Show this help",
                          "steer" => "park a note for the subagent" }
        )
      end

      it "renders the command description next to its name in the dropdown" do
        "/he".each_char { |ch| composer.handle_key(ch) }
        expect(composer.menu_open?).to be(true)
        frame = output.string
        expect(frame).to include("/help")
        expect(frame).to include("Show this help")
      end

      it "leaves an undescribed candidate bare (no stray column)" do
        "/ag".each_char { |ch| composer.handle_key(ch) }
        rows = composer.send(:menu_rows)
        expect(rows.first).to include("/agents")
        # No description registered for /agents: nothing after the name.
        expect(rows.first.rstrip).to end_with("/agents")
      end

      it "offers the live subagent ids for `/agents `" do
        "/agents ".each_char { |ch| composer.handle_key(ch) }
        expect(composer.menu_open?).to be(true)
        expect(output.string).to include("sa_aaaa")
      end

      it "offers steer/probe/--stop after the id, with the usage hint" do
        "/agents sa_aaaa ".each_char { |ch| composer.handle_key(ch) }
        expect(composer.menu_open?).to be(true)
        frame = output.string
        expect(frame).to include("steer")
        expect(frame).to include("--stop")
        expect(frame).to include("park a note for the subagent")
      end

      it "accepts a subcommand into the buffer (Tab on --stop)" do
        "/agents sa_aaaa --s".each_char { |ch| composer.handle_key(ch) }
        tab(composer)
        expect(composer.buffer).to eq("/agents sa_aaaa --stop ")
      end
    end
  end

  describe "#handle_key Ctrl+O (reveal reasoning)" do
    it "invokes the on_ctrl_o callback and does not touch the buffer" do
      called = 0
      c = described_class.new(input_queue: queue, input: input, output: output,
                              on_ctrl_o: -> { called += 1 })
      "ab".each_char { |ch| c.handle_key(ch) }
      result = c.handle_key("\x0f")
      expect(called).to eq(1)
      expect(result).to be_nil
      expect(c.buffer).to eq("ab") # the byte never lands in the input line
    end

    it "is a quiet no-op when no callback is wired" do
      expect { composer.handle_key("\x0f") }.not_to raise_error
    end

    # D1: while the ANSWER content is actively streaming, Ctrl+O must NOT commit
    # the `┊` aside between chunks (it would bisect the answer). The reveal is
    # DEFERRED and flushed once the stream ends, so it renders after the answer.
    it "DEFERS the reveal while content is streaming, flushing it on stream end (D1)" do
      called = []
      c = described_class.new(input_queue: queue, input: input, output: output,
                              on_ctrl_o: -> { called << :reveal })
      c.begin_content_stream
      expect(c.streaming?).to be(true)
      c.handle_key("\x0f")            # Ctrl+O mid-stream
      expect(called).to eq([])        # NOT revealed yet (no aside between chunks)
      c.end_content_stream            # answer block finished
      expect(called).to eq([:reveal]) # now flushed, cleanly after the answer
    end

    it "reveals immediately when NOT streaming (idle Ctrl+O is unchanged)" do
      called = []
      c = described_class.new(input_queue: queue, input: input, output: output,
                              on_ctrl_o: -> { called << :reveal })
      c.handle_key("\x0f")
      expect(called).to eq([:reveal])
    end

    it "flushes at most one deferred reveal per stream (no double-commit)" do
      called = []
      c = described_class.new(input_queue: queue, input: input, output: output,
                              on_ctrl_o: -> { called << :reveal })
      c.begin_content_stream
      c.handle_key("\x0f")
      c.handle_key("\x0f") # mashed twice mid-stream
      c.end_content_stream
      expect(called).to eq([:reveal]) # one flush, not two
    end
  end

  describe "#handle_key Tab (agent cycle on empty input)" do
    # #320: a Tab with nothing to complete (empty buffer, no menu) cycles the
    # active PRIMARY agent and adopts the returned status line — the agent
    # counterpart of Shift+Tab's mode cycle.
    it "invokes on_agent_cycle and adopts the returned STATUS line" do
      cycles = 0
      c = described_class.new(input_queue: queue, input: input, output: output,
                              on_agent_cycle: lambda {
                                cycles += 1
                                " default · agent plan · m3"
                              })
      c.handle_key("\t")
      expect(cycles).to eq(1)
      expect(output.string).to include(" default · agent plan · m3")
    end

    it "does NOT cycle the agent when there is text in the buffer (Tab stays completion)" do
      cycles = 0
      c = described_class.new(input_queue: queue, input: input, output: output,
                              on_agent_cycle: -> { cycles += 1 })
      "/he".each_char { |ch| c.handle_key(ch) } # a typed, completable token
      c.handle_key("\t")
      expect(cycles).to eq(0)
    end

    it "is a quiet no-op when no callback is wired" do
      expect { composer.handle_key("\t") }.not_to raise_error
    end
  end

  describe "#handle_key Shift+Tab (mode cycle)" do
    # Shift+Tab arrives as ESC[Z: preload the bytes after ESC, then trigger the
    # escape consumer via handle_key("\e") — the same way the paste specs drive it.
    it "invokes on_mode_cycle and adopts the returned STATUS line (mode lives in the statusbar)" do
      cycles = 0
      io = StringIO.new("[Z")
      c = described_class.new(input_queue: queue, input: io, output: output,
                              on_mode_cycle: lambda {
                                cycles += 1
                                " yolo · m3 · ctx ~1k/64k"
                              })
      c.handle_key("\e")
      expect(cycles).to eq(1)
      expect(output.string).to include(" yolo · m3 · ctx ~1k/64k") # the statusbar was redrawn live
    end

    it "a nil return (e.g. the yolo arm toast) leaves the statusbar untouched" do
      io = StringIO.new("[Z")
      c = described_class.new(input_queue: queue, input: io, output: output,
                              status_line: " plan · m3", on_mode_cycle: -> {})
      c.set_partial("") # force one frame so the bar is on screen
      c.handle_key("\e")
      frames = output.string
      expect(frames).to include(" plan · m3") # still the original bar
    end

    it "is a quiet no-op when no callback is wired" do
      io = StringIO.new("[Z")
      expect do
        composer.handle_key("\e")
        composer.instance_variable_get(:@escapes).send(:read_nonblock_char)
      end.not_to raise_error
      composer2 = described_class.new(input_queue: queue, input: io, output: output)
      expect { composer2.handle_key("\e") }.not_to raise_error
    end
  end

  # D2/D3: the mode confirmation is a TRANSIENT live-region row (#announce), not
  # a committed print_above line. Cycling N times must leave ZERO stacked banner
  # lines in scrollback — only the prompt chip reflects the mode.
  describe "#announce (transient mode confirmation)" do
    it "renders the banner in the live region above the prompt" do
      composer.handle_key("x")
      composer.announce("┄ mode · plan ┄")
      expect(output.string).to include("┄ mode · plan ┄\r\n")
      expect(output.string).to end_with("#{PROMPT}x")
    end

    it "REPLACES (does not stack) the banner when cycled again" do
      composer.announce("┄ mode · plan ┄")
      output.truncate(0)
      output.rewind
      composer.announce("┄ mode · yolo ┄")
      # The prior banner row is cleared in place (cursor-up), not scrolled — the
      # new frame shows only the latest banner.
      expect(output.string).to include("\e[1A\e[2K")
      expect(output.string).to include("┄ mode · yolo ┄")
      expect(output.string).not_to include("plan")
    end

    it "is cleared by the next keystroke (one-shot toast, no scrollback)" do
      composer.announce("┄ mode · plan ┄")
      composer.handle_key("a") # any keystroke dismisses the toast
      # The latest frame is just the prompt + buffer; the banner is gone.
      last_frame = output.string.split("\r\e[2K").last
      expect(last_frame).not_to include("mode · plan")
      expect(composer.instance_variable_get(:@announce)).to eq("")
    end

    it "cycling repeatedly leaves no banner residue after a keystroke (D3)" do
      # Three announce → keystroke cycles, mirroring default→plan→yolo→default.
      %w[plan yolo default].each do |m|
        composer.announce("┄ mode · #{m} ┄")
        composer.handle_key(" ") # a keystroke dismisses each toast
      end
      # The final frame carries no committed banner line for any mode.
      last_frame = output.string.split("\r\e[2K").last
      %w[plan yolo default].each { |m| expect(last_frame).not_to include("mode · #{m}") }
    end
  end

  # #426 (Bug B): the during-turn Ctrl+C double-tap hint. The chat loop's SIGINT
  # trap used to write "\n(press Ctrl+C again to exit)\n" RAW to the terminal,
  # scrolling the live region by two rows OUTSIDE LiveRegion's @rows_above
  # accounting. On a very-early interrupt — the answer's first line still a raw
  # live-tail preview — that desynced the geometry, so the finalize commit's
  # \e[1A walk-up fell one row short: the raw preview SURVIVED above the rendered
  # (curly) line and the prompt committed as a ghost `❯`, duplicating the
  # preamble. #announce_pending is the TRAP-SAFE fix: it only ASSIGNS @announce
  # (no render mutex — forbidden in trap context — and no output), and the next
  # mutex-held frame paints the hint as an IN-PLACE transient row that never
  # scrolls, so the geometry stays in step and the finalize erases the preview.
  describe "#announce_pending (trap-safe during-turn hint, #426 Bug B)" do
    it "sets the transient @announce WITHOUT taking the render mutex or emitting" do
      # Trap-safe contract: a SIGINT trap can call this, so it must NOT lock the
      # render mutex (Mutex#lock raises in trap context) and must NOT write any
      # bytes (a raw scrolling write is what desynced the geometry — Bug B).
      mutex = composer.instance_variable_get(:@render)
      expect(mutex).not_to receive(:synchronize)
      output.truncate(0)
      output.rewind

      composer.announce_pending("(press Ctrl+C again to exit)")

      expect(composer.instance_variable_get(:@announce)).to eq("(press Ctrl+C again to exit)")
      expect(output.string).to eq("") # zero bytes — the next frame paints it
    end

    it "renders the pending hint as an IN-PLACE live row on the next frame, never a raw scroll" do
      # The interrupt's finalize redraw is the next mutex-held frame; it must
      # paint the hint as a transient live row (\r\e[2K…\r\n above the prompt) —
      # NOT as a raw "\n…\n" that scrolls the region (the desync that stranded
      # the raw preview above the rendered line as the duplicated preamble).
      composer.announce_pending("(press Ctrl+C again to exit)")
      output.truncate(0)
      output.rewind

      composer.send(:redraw) # stand-in for the interrupt's finalize repaint

      expect(output.string).to include("\r\e[2K(press Ctrl+C again to exit)")
      expect(output.string).not_to include("\r\n(press Ctrl+C again to exit)\r\n")
      expect(output.string).to end_with(PROMPT)
    end

    it "leaves the hint cleared on the next keystroke (one-shot toast, no scrollback)" do
      composer.announce_pending("(press Ctrl+C again to exit)")
      composer.handle_key("a") # any keystroke dismisses the toast
      expect(composer.instance_variable_get(:@announce)).to eq("")
    end
  end

  describe "bracketed paste (L1)" do
    # Drive a paste by preloading the input IO with the bytes that follow the
    # initial ESC, then triggering the escape consumer via handle_key("\e").
    def paste(body)
      io = StringIO.new("[200~#{body}\e[201~")
      c  = described_class.new(input_queue: queue, input: io, output: output)
      c.handle_key("\e")
      c
    end

    # #57: a multi-line paste keeps its REAL newlines in the buffer (and in
    # the submitted payload), instead of the old D6 collapse to spaces that
    # destroyed pasted code structure. The paste is NOT auto-submitted — each
    # embedded \n lands in the buffer, editable, drawn as a visible ⏎ mark.
    it "preserves a multi-line paste's newlines in the editable buffer (#57)" do
      c = paste("def add(a, b)\n  a + b\nend")
      expect(queue.drain).to eq([]) # not auto-submitted
      expect(c.buffer).to eq("def add(a, b)\n  a + b\nend")
    end

    it "submits the pasted newlines intact in the message payload (#57)" do
      c = paste("line1\nline2")
      c.handle_key("\r")
      expect(queue.drain).to eq(["line1\nline2"])
    end

    it "draws buffer newlines as REAL row breaks in the multi-row input block" do
      paste("line1\nline2")
      # The final frame draws each logical line on its own visual row: the
      # prompt row ends in a CRLF row break, then the continuation row.
      frame = output.string.split("\r\e[2K#{PROMPT}").last
      expect(frame).to start_with("line1\r\n")
      expect(frame).to include("\r\e[2K  line2") # hanging indent (P12)
      expect(frame).not_to include("⏎")
    end

    it "normalizes CR / CRLF pasted line breaks to \n" do
      expect(paste("a\r\nb").buffer).to eq("a\nb")
      expect(paste("a\rb").buffer).to eq("a\nb")
    end

    it "preserves interior blank lines but trims the trailing newline" do
      expect(paste("a\n\n\nb\n").buffer).to eq("a\n\n\nb")
    end

    it "appends a single-line paste to the editable buffer (not auto-submitted)" do
      c = paste("inline text")
      expect(queue.drain).to eq([])
      expect(c.buffer).to eq("inline text")
    end

    it "inserts the paste AT the cursor, like fast typing" do
      c = described_class.new(input_queue: queue, input: input, output: output)
      "ac".each_char { |ch| c.handle_key(ch) }
      c.instance_variable_set(:@input, StringIO.new("[200~X\nY\e[201~"))
      c.handle_key("\x02") # Ctrl+B: cursor between a and c
      c.handle_key("\e")   # trigger the preloaded paste
      expect(c.buffer).to eq("aX\nYc")
    end
  end

  # The file-backed paste pipeline (UI::PasteStore): with a store wired, a
  # paste longer than paste.collapse_lines inserts ONE compact
  # "[Pasted text #N +M lines]" placeholder instead of the body. The token is
  # a single editable unit — backspace deletes it whole, typing around it
  # leaves it intact — and the SUBMITTED line still carries the placeholder:
  # expansion to the full body happens at the chat loop's message-build seam
  # (ChatCommand#run_turn → PasteStore#expand), so echo/history/queueing all
  # stay compact while the model sees everything.
  describe "paste pipeline (placeholder collapse)" do
    let(:store) do
      Rubino::UI::PasteStore.new(
        config: instance_double(Rubino::Config::Configuration,
                                paste_collapse_lines: 5,
                                paste_collapse_chars: 10_000, # high: this exercises the LINE boundary
                                paste_file_threshold_tokens: 8000),
        session_source: "composer-spec"
      )
    end
    let(:big) { Array.new(50) { |i| "line #{i + 1}" }.join("\n") }

    def build(echo: :queued)
      described_class.new(input_queue: queue, input: input, output: output,
                          paste_store: store, echo: echo,
                          history: Rubino::UI::InputHistory.new(store: []))
    end

    def paste_into(composer, body)
      composer.instance_variable_set(:@input, StringIO.new("[200~#{body}\e[201~"))
      composer.handle_key("\e")
      composer
    end

    it "collapses a paste OVER the threshold to a single placeholder token" do
      c = paste_into(build, big)
      expect(c.buffer).to eq("[Pasted text #1 +50 lines]")
    end

    it "keeps a paste AT the threshold inline (boundary: 5 lines, default 5)" do
      c = paste_into(build, "a\nb\nc\nd\ne")
      expect(c.buffer).to eq("a\nb\nc\nd\ne")
    end

    it "numbers a second paste #2 in the same draft" do
      c = paste_into(build, big)
      c.handle_key(" ")
      paste_into(c, Array.new(6) { "x" }.join("\n"))
      expect(c.buffer).to eq("[Pasted text #1 +50 lines] [Pasted text #2 +6 lines]")
    end

    it "backspace deletes the placeholder WHOLE (never a half-eaten token)" do
      c = paste_into(build, big)
      c.handle_key("\x7F")
      expect(c.buffer).to eq("")
    end

    it "deletes char-by-char around the token, whole-token only ON it" do
      c = paste_into(build, big)
      "xy".each_char { |ch| c.handle_key(ch) }
      c.handle_key("\x7F") # eats "y"
      expect(c.buffer).to eq("[Pasted text #1 +50 lines]x")
      c.handle_key("\x7F") # eats "x"
      c.handle_key("\x7F") # eats the whole token
      expect(c.buffer).to eq("")
    end

    it "edits AROUND the token and submits with the placeholder in the payload" do
      c = paste_into(build, big)
      c.handle_key("\x01") # Ctrl+A → home
      "see ".each_char { |ch| c.handle_key(ch) }
      c.handle_key("\x05") # Ctrl+E → end
      " ok".each_char { |ch| c.handle_key(ch) }
      c.handle_key("\r")
      expect(queue.drain).to eq(["see [Pasted text #1 +50 lines] ok"])
    end

    it "expands the submitted line to the FULL body at the message-build seam" do
      c = paste_into(build, big)
      c.handle_key("\r")
      line = queue.drain.first
      expect(line).to eq("[Pasted text #1 +50 lines]")
      expect(store.expand(line)).to eq(big) # what run_turn hands the model
    end

    it "echoes an idle submit with the placeholder — scrollback stays clean" do
      c = build(echo: :prompt)
      paste_into(c, big)
      output.truncate(0)
      output.rewind
      c.handle_key("\r")
      expect(output.string).to include("#{PROMPT}[Pasted text #1 +50 lines]")
      expect(output.string).not_to include("line 42")
    end

    it "survives ↑ history recall: the recalled draft still expands" do
      c = paste_into(build, big)
      c.handle_key("\r")
      queue.drain
      c.send(:history_up)
      expect(c.buffer).to eq("[Pasted text #1 +50 lines]")
      expect(store.expand(c.buffer)).to eq(big)
    end

    it "queues with Alt+Enter mid-turn, placeholder intact and expandable" do
      c = paste_into(build, big)
      c.begin_turn
      c.instance_variable_set(:@input, StringIO.new("\r"))
      c.handle_key("\e") # ESC + CR = Alt+Enter → queue without interrupting
      line = queue.drain.first
      expect(line).to eq("[Pasted text #1 +50 lines]")
      expect(store.expand(line)).to eq(big)
    end

    it "inlines every paste when NO store is wired (standalone, legacy)" do
      c = described_class.new(input_queue: queue, input: input, output: output)
      c.instance_variable_set(:@input, StringIO.new("[200~#{big}\e[201~"))
      c.handle_key("\e")
      expect(c.buffer).to eq(big)
    end
  end

  describe "#print_above" do
    it "erases the input line, writes the output, then redraws the input" do
      composer.handle_key("h")
      composer.handle_key("i")
      output.truncate(0)
      output.rewind
      composer.print_above("agent line")
      frame = output.string
      # 1) clear-line, 2) the output + CRLF, 3) the redrawn input
      expect(frame).to include("\r\e[2K")
      expect(frame).to include("agent line\r\n")
      expect(frame).to end_with("#{PROMPT}hi")
    end

    it "converts embedded newlines to CRLF (OPOST off in raw mode)" do
      composer.print_above("a\nb")
      expect(output.string).to include("a\r\nb\r\n")
    end

    # P3: an empty committed line is a DELIBERATE blank row (the rhythm gaps
    # before the answer / before a tool run) — it must scroll one real row,
    # not be silently dropped.
    it "an empty argument commits one blank row above the prompt" do
      composer.handle_key("x")
      output.truncate(0)
      output.rewind
      composer.print_above("")
      expect(output.string).to include("\r\n")
      expect(output.string).to end_with("#{PROMPT}x")
    end
  end

  describe "#set_partial (live streamed line)" do
    it "renders the partial on a transient row above the prompt" do
      composer.handle_key("q")
      composer.set_partial("streaming tok")
      expect(composer.partial?).to be(true)
      # partial row, then CRLF, then the prompt row
      expect(output.string).to include("streaming tok\r\n")
      expect(output.string).to end_with("#{PROMPT}q")
    end

    it "a committed print_above clears the live partial" do
      composer.set_partial("half a line")
      composer.print_above("finished line")
      expect(composer.partial?).to be(false)
      expect(output.string).to include("finished line\r\n")
    end

    it "walks up to clear a stale partial row before the next frame" do
      composer.set_partial("aaa")
      composer.set_partial("aaabbb")
      # The cursor-up + clear (\e[1A\e[2K) appears so the prior partial row is
      # overwritten in place rather than scrolled.
      expect(output.string).to include("\e[1A\e[2K")
    end
  end

  describe "#set_cards (subagent card block, Variant A)" do
    it "renders each card on its own row above the prompt, prompt redrawn last" do
      composer.handle_key("x")
      composer.set_cards(["▸ sa_1 · explore · running", "▸ sa_2 · test · running"])
      expect(output.string).to include("▸ sa_1 · explore · running\r\n")
      expect(output.string).to include("▸ sa_2 · test · running\r\n")
      expect(output.string).to end_with("#{PROMPT}x")
      expect(composer.cards.size).to eq(2)
    end

    it "updates the block IN PLACE (walks up to clear the prior rows, no flood)" do
      composer.set_cards(["▸ sa_1 · running · 1 tool"])
      output.truncate(0)
      output.rewind
      composer.set_cards(["▸ sa_1 · running · 2 tools"])
      # The prior card row is cleared via cursor-up (\e[1A\e[2K) rather than a
      # fresh line scrolling the old one up — the in-place card contract.
      expect(output.string).to include("\e[1A\e[2K")
      expect(output.string).to include("2 tools")
      # No duplication: the old "1 tool" text isn't re-emitted in this frame.
      expect(output.string).not_to include("1 tool")
    end

    it "clears the card block when given an empty list" do
      composer.set_cards(["▸ sa_1 · running"])
      composer.set_cards([])
      expect(composer.cards).to eq([])
      # After clearing, the live region is just the prompt row.
      expect(output.string).to end_with(PROMPT)
    end

    it "caps the block at MAX_CARD_ROWS so a buggy caller can't push the prompt off-screen" do
      composer.set_cards(Array.new(20) { |i| "card #{i}" })
      expect(composer.cards.size).to eq(described_class::MAX_CARD_ROWS)
    end

    it "coexists with a live streamed partial (cards above, partial above prompt)" do
      composer.set_cards(["▸ sa_1 · running"])
      composer.set_partial("streaming token")
      expect(output.string).to include("▸ sa_1 · running\r\n")
      expect(output.string).to include("streaming token\r\n")
      expect(composer.cards.size).to eq(1)
      expect(composer.partial?).to be(true)
    end

    it "a committed print_above repaints cards above the committed line + prompt" do
      composer.set_cards(["▸ sa_1 · running"])
      composer.print_above("a finished timeline row")
      expect(output.string).to include("a finished timeline row\r\n")
      # The card survives a commit (it's persistent live-region state).
      expect(output.string).to include("▸ sa_1 · running\r\n")
    end
  end

  describe "render mutex serializes concurrent frames" do
    it "interleaved print_above + keystrokes never corrupt the buffer" do
      threads = []
      threads << Thread.new do
        200.times { |i| composer.print_above("out #{i}") }
      end
      threads << Thread.new do
        ("a".."z").cycle.first(200).each { |c| composer.handle_key(c) }
      end
      threads.each(&:join)
      # The buffer holds exactly the 200 typed chars (mutex kept appends atomic
      # against concurrent redraws).
      expect(composer.buffer.length).to eq(200)
      expect(composer.buffer).to match(/\A[a-z]+\z/)
    end
  end

  describe "#resize" do
    it "recomputes width and redraws under the mutex" do
      composer.handle_key("z")
      allow(output).to receive(:winsize).and_return([24, 10])
      output.truncate(0)
      output.rewind
      composer.resize
      expect(output.string).to end_with("#{PROMPT}z")
    end

    it "repaints the live streamed partial on resize so mid-stream output isn't wiped (X1)" do
      composer.set_partial("streaming answer in progress")
      output.truncate(0)
      output.rewind
      composer.resize
      # The partial text is re-emitted (not left blank until the turn commits).
      expect(output.string).to include("streaming answer in progress")
      # The prompt is redrawn below it.
      expect(output.string).to end_with(PROMPT)
    end

    # #401: typing a long line then resizing (the column count changes, so the
    # terminal reflows the wrapped input into a DIFFERENT number of physical
    # rows) re-echoed/duplicated the in-progress input ~20× into scrollback on
    # each reflow. Root cause: the resize redraw walked the OLD on-screen row
    # geometry (@input_above/@rows_above recorded at the previous width) with a
    # relative \e[1A\e[2K walk-up — under-clearing left the stale copy and the
    # fresh redraw appended BELOW it, stacking a copy per reflow. The fix forgets
    # the row geometry before redrawing (the same {LiveRegion#reset_geometry!}
    # seam Ctrl+L/#395 uses) so the next frame draws ONE clean copy.
    it "forgets the stale row geometry before redrawing on resize (#401)" do
      region = composer.instance_variable_get(:@region)
      # Type a long line that wraps to several physical rows at the start width,
      # so a real on-screen geometry (input_above) is recorded.
      "x".ljust(120, "x").each_char { |ch| composer.handle_key(ch) }
      expect(region.input_above).to be_positive # multi-row before resize

      output.truncate(0)
      output.rewind
      # Resize: reset_geometry! must run BEFORE the redraw walks the stale rows.
      expect(region).to receive(:reset_geometry!).and_call_original.ordered
      expect(region).to receive(:clear_input_block).and_call_original.ordered
      allow(output).to receive(:winsize).and_return([24, 200])
      composer.resize

      # And the reflowed input is emitted exactly ONCE, not duplicated: the
      # buffer text appears a single time in the post-resize byte stream.
      expect(output.string.scan("#{PROMPT}#{"x" * 120}").length).to eq(1)
    end

    # Guard the Ctrl+L (#395) and the plain redraw paths the #401 fix sits next
    # to: reset_geometry! must NOT leak into a non-resize redraw (a stale-geometry
    # reset there would desync the in-place clear), and Ctrl+L must still clear.
    it "does NOT reset geometry on a normal (non-resize) redraw" do
      composer.handle_key("a")
      region = composer.instance_variable_get(:@region)
      expect(region).not_to receive(:reset_geometry!)
      composer.send(:redraw)
    end

    # #481: after a SIGWINCH resize, typing a line long enough to WRAP re-committed
    # the first visual row on every keystroke (12+ stair-stepped duplicates into
    # scrollback). Root cause: the cheap keystroke path (#draw_input) reused a
    # @cols that #resize could record STALE — a drag coalesces SIGWINCHes and the
    # trap can read winsize BEFORE the pty commits the new size — so a wrapping
    # line laid out as ONE logical row at the stale width while the physical
    # terminal wrapped it onto a 2nd line the single-row clear never erased. The
    # fix re-reads the live winsize in #draw_input (like #render_frame), so the
    # wrap math matches the true width and the clear count is exact.
    describe "wrapping after a resize whose recorded width went stale (#481)" do
      subject(:composer) do
        described_class.new(input_queue: queue, input: input, output: racy_out)
      end

      # An output whose #winsize answer can drift from the @cols #resize last
      # recorded — the SIGWINCH-race the duplication needs.
      let(:racy_out) do
        Class.new(StringIO) do
          attr_writer :cols

          def initialize
            super
            @cols = 80
          end

          def winsize = [24, @cols]
        end.new
      end

      it "self-heals @cols on the keystroke path so a wrapping line is not duplicated" do
        composer.send(:redraw) # initial draw at width 80
        # Resize fires but winsize still reports the OLD 80 (the trap raced the
        # pty commit), so #resize records a stale @cols = 80.
        composer.resize
        expect(composer.instance_variable_get(:@cols)).to eq(80)

        # The terminal is ACTUALLY 40 wide now.
        racy_out.cols = 40
        region = composer.instance_variable_get(:@region)

        # Type a 50-char line: at the stale 80 it would be one logical row (and
        # physically wrap, stair-stepping); the fix re-reads 40 in #draw_input,
        # so it wraps to TWO logical rows the clear tracks.
        racy_out.truncate(0)
        racy_out.rewind
        50.times { |i| composer.handle_key((97 + (i % 26)).chr) }

        expect(composer.instance_variable_get(:@cols)).to eq(40) # healed
        expect(region.input_above).to be_positive                # laid out multi-row

        # The line scrolls a row into scrollback EXACTLY ONCE (the single 1→2
        # row transition), never once-per-keystroke. Net commits = CRLFs that are
        # not matched by a preceding clear-up.
        s = racy_out.string
        net = s.scan("\r\n").length - s.scan("\e[1A").length
        expect(net).to eq(1)
      end
    end

    # Non-trigger (#481): narrow typing WITHOUT a prior resize stays correct —
    # the width is right from the start, so a wrapping line clears in place.
    it "does NOT duplicate when typing a wrapping line without any resize" do
      region = composer.instance_variable_get(:@region)
      50.times { |i| composer.handle_key((97 + (i % 26)).chr) } # width 40 (FakeTermIO)
      expect(region.input_above).to be_positive
      s = output.string
      net = s.scan("\r\n").length - s.scan("\e[1A").length
      expect(net).to eq(1) # one clean 1→2 row growth, not N duplicates
    end
  end

  # #421: the stream FINALIZE / INTERRUPT / force-summary commit repaints run
  # after the status-row ticker + a flurry of transient frames have left the
  # region's recorded geometry out of step with the physical rows, so the next
  # #print_above walked one row short and stranded the live prompt (ghost `❯`) /
  # repainted the kept partial twice. #finalize_region row-accurately erases the
  # live region and zeroes its geometry so the closing commit lands as ONE clean
  # frame — the same {LiveRegion#clear}/reset discipline #stop and Ctrl+L use.
  describe "#finalize_region (#421)" do
    it "erases the live region in place and zeroes the on-screen geometry" do
      # Paint a live partial so a real on-screen geometry (rows_above) is recorded.
      composer.set_partial("◆┄┄┄┄ thinking · 3s · esc to interrupt")
      region = composer.instance_variable_get(:@region)
      expect(region.rows_above).to be_positive # something is live above the prompt

      output.truncate(0)
      output.rewind
      composer.finalize_region

      # Geometry is reset to a clean blank top row: the partial dropped, the
      # above-prompt row count zeroed (nothing stale left for the next commit).
      expect(region.rows_above).to eq(0)
      expect(composer.instance_variable_get(:@partial)).to eq("")
      # The erase walked UP and cleared (the row-accurate \e[1A\e[2K), then the
      # prompt was redrawn fresh.
      expect(output.string).to include("\e[1A\e[2K")
      expect(output.string).to end_with(PROMPT)
    end

    it "redraws subagent cards that are still live after the erase" do
      composer.set_cards(["▸ sa_e488 · explore · running"])
      output.truncate(0)
      output.rewind
      composer.finalize_region
      # The card survives the reset (it is re-emitted), so finalize doesn't wipe
      # legitimately-live above-prompt rows, only resets the geometry.
      expect(output.string).to include("sa_e488")
    end

    it "is callable repeatedly without raising (idempotent clean state)" do
      expect { 2.times { composer.finalize_region } }.not_to raise_error
      expect(composer.instance_variable_get(:@region).rows_above).to eq(0)
    end
  end

  describe "reader teardown handoff (#80 — first keystroke must survive)" do
    # The #80 safety bug: when the approval menu opened, the composer's raw
    # reader was torn down with Thread#kill while blocked in a bare getc. A byte
    # already waiting in $stdin at that instant could be returned by the dying
    # getc (and swallowed into the composer draft) before TTY::Prompt took over,
    # so the menu lost the user's FIRST arrow and navigation landed one item
    # short — turning an intended deny into an approve.
    #
    # The contract the fix establishes: when the reader is stopped, ANY byte
    # already buffered in $stdin is left untouched for the next consumer (the
    # menu). We assert it deterministically with a real pipe as $stdin: the
    # reader blocks in its select (no byte yet), we then write a byte and stop
    # the reader, and the byte must still be readable afterwards — i.e. the
    # reader exited WITHOUT consuming it. Termios calls are stubbed so the real
    # select/getc seam runs without a TTY.
    subject(:composer) do
      described_class.new(input_queue: queue, input: read_io, output: output)
    end

    let(:reader_pipe) { IO.pipe }
    let(:read_io)  { reader_pipe.first }
    let(:write_io) { reader_pipe.last }

    before do
      # Neutralise termios so the real select+getc seam runs against a plain pipe
      # (no TTY): raw just yields, cooked!/tty? are inert.
      allow(read_io).to receive(:raw) { |*_, &blk| blk.call }
      allow(read_io).to receive(:cooked!)
      allow(read_io).to receive(:tty?).and_return(false)
    end

    after do
      [read_io, write_io].each { |io| io.close unless io.closed? }
    end

    it "exits on the stop signal WITHOUT consuming a pending $stdin byte (the first key survives the handoff)" do
      # Reproduce the exact teardown condition of #80 deterministically: a
      # keystroke is already waiting in $stdin AND the stop signal is raised, so
      # the reader's select sees BOTH ready at once. The reader must honour the
      # stop and exit without reading $stdin — leaving the byte for TTY::Prompt.
      # Pre-fix (a bare getc killed mid-read) the dying getc returned that byte
      # and swallowed it into the composer draft.
      #
      # We force the both-ready wake by stubbing IO.select on the reader's first
      # call to report the input AND the stop pipe simultaneously, removing all
      # timing dependence. If the reader calls getc under that condition, the test
      # fails — that is precisely the pre-fix swallow.
      write_io.write("\e") # first byte of an arrow-key CSI sequence, pending in $stdin

      consumed = false
      allow(read_io).to receive(:getc).and_wrap_original do |orig|
        consumed = true
        orig.call
      end

      # First select call: report BOTH $stdin and the stop pipe ready at once
      # (the race window). The reader must check the stop pipe FIRST and break.
      # The reader selects on [@input, stop_r, wake_r] (the wake pipe was added
      # for the mid-turn auto-open). Report $stdin AND the stop pipe ready at
      # once (the race window) — wake NOT ready — so the reader must check the
      # stop pipe FIRST and break without reading $stdin.
      first = true
      allow(IO).to receive(:select).and_wrap_original do |orig, ios, *rest|
        if first && ios.length >= 2
          first = false
          [[ios[0], ios[1]], [], []] # @input + stop pipe readable simultaneously
        else
          orig.call(ios, *rest)
        end
      end

      composer.start
      # Let the reader actually RUN before tearing it down. On the fixed reader
      # the stubbed both-ready select returns at once and the thread exits (not
      # alive); on a kill-based bare-getc reader (the #80 bug) the thread
      # reaches its read, consumes the pending byte right here, and then blocks
      # ("sleep"). Without this wait a bare-getc+kill revert sneaks past: the
      # kill in #stop lands before the spawned thread is ever scheduled, so the
      # byte survives by scheduling accident, not by contract.
      reader = composer.instance_variable_get(:@reader)
      deadline = Time.now + 5
      Thread.pass while reader.alive? && reader.status != "sleep" && Time.now < deadline
      composer.stop

      # The reader never read $stdin during teardown...
      expect(consumed).to be(false)
      # ...so the byte is still there for the menu — the first key survived.
      expect(read_io.read_nonblock(1)).to eq("\e")
      # ...and it was NOT buffered into the composer draft (the pre-fix symptom).
      expect(composer.buffer).to eq("")
    end

    it "stops the reader thread deterministically (joined, not merely signalled)" do
      composer.start
      # Let the reader reach its blocking select on the empty pipe.
      Thread.pass until composer.instance_variable_get(:@reader)&.status == "sleep"
      reader = composer.instance_variable_get(:@reader)
      expect(reader).to be_alive
      composer.stop
      # The reader is fully gone (the join completed), not left racing a kill.
      expect(reader).not_to be_alive
    end
  end

  describe ".run_in_terminal (prompt_toolkit run_in_terminal pattern)" do
    # Stub the raw reader so #start/#resume don't touch real terminal modes —
    # the contract under test is the lifecycle (reader stopped/restarted,
    # $stdout swapped, buffer preserved), not the raw read itself.
    let(:reader_threads) { [] }

    before do
      allow(composer).to receive(:start_reader) do
        t = Thread.new { sleep }
        reader_threads << t
        t
      end
    end

    after { composer.stop }

    it "just yields when no composer is active (off-turn / piped input)" do
      Rubino::UI::BottomComposer.current = nil
      yielded = false
      result = described_class.run_in_terminal do
        yielded = true
        :done
      end
      expect(yielded).to be(true)
      expect(result).to eq(:done)
    end

    it "registers the running composer as current on #start, clears it on #stop" do
      expect(described_class.current).not_to equal(composer)
      composer.start
      expect(described_class.current).to equal(composer)
      composer.stop
      expect(described_class.current).to be_nil
    end

    it "suspends for the block (reader stopped, real $stdout restored) and resumes after" do
      composer.start
      "draft".each_char { |c| composer.handle_key(c) }

      # The proxy stands in for the StdoutProxy active during a turn. $stdout=
      # requires a #write method (the StdoutProxy has one; bare Object does not).
      proxy = Object.new
      def proxy.write(*) = 0
      $stdout = proxy
      reader_before = reader_threads.last

      inside_stdout = nil
      reader_alive_inside = nil
      described_class.run_in_terminal do
        inside_stdout = $stdout
        reader_alive_inside = reader_before.alive?
      end

      # During the block: $stdout is the REAL IO (the composer's @output), and
      # the reader thread was stopped.
      expect(inside_stdout).to equal(output)
      expect(reader_alive_inside).to be(false)

      # After the block: $stdout is back to the proxy, a fresh reader is running,
      # and the typed draft survived.
      expect($stdout).to equal(proxy)
      expect(reader_threads.last).not_to equal(reader_before)
      expect(reader_threads.last.alive?).to be(true)
      expect(composer.buffer).to eq("draft")
    ensure
      $stdout = STDOUT
    end

    # #144: while an approval/ask owns the real terminal (suspended), a
    # background subagent's card repaint must NOT paint over the interactive
    # prompt — a frame racing the blocked TTY read is what auto-resolved the
    # [o/a/n] prompt to Denied. Frames are dropped like #set_partial's; the
    # registry snapshot converges on the next repaint after #resume.
    it "drops #set_cards frames while suspended, paints again after resume (#144)" do
      composer.start
      composer.suspend
      before_len = output.string.length
      composer.set_cards(["● sa_1 · explore · running"])
      expect(output.string.length).to eq(before_len) # nothing drawn over the prompt

      composer.resume
      composer.set_cards(["● sa_1 · explore · running"])
      expect(output.string).to include("sa_1")
    end
  end

  # Multi-row input growth: a buffer longer than the terminal width WRAPS and
  # the input block grows downward (like Claude Code), instead of the old
  # single-row horizontal scroll-window. winsize is [24, 40] → the per-row
  # budget is 39 columns; row 0 carries the 2-col "❯ " prompt, so it holds 37
  # chars and continuation rows hold 39.
  describe "multi-row input growth" do
    def type(text, into: composer)
      text.each_char { |ch| into.handle_key(ch) }
    end

    # Feed an escape sequence (e.g. "[A" for ↑) the way the arrow specs do:
    # preload the byte tail, then trigger the consumer with ESC.
    def escape(seq, into: composer)
      into.instance_variable_set(:@input, StringIO.new(seq))
      into.handle_key("\e")
    end

    # The last full input-block frame: everything from the final prompt draw.
    def last_block
      output.string.split("\r\e[2K#{PROMPT}").last
    end

    it "stays one visual row while the buffer fits (no row break)" do
      type("a" * 37)
      expect(last_block).to eq("a" * 37) # no CRLF, caret already at EOL
    end

    it "grows a second visual row at the wrap boundary (38th char)" do
      type("a" * 38)
      expect(last_block).to eq("#{"a" * 37}\r\n\r\e[2K  a") # indented continuation (P12)
    end

    it "grows one row per width multiple (37 + 37 + … — hanging indent, P12)" do
      type("a" * (37 + 37 + 5))
      expect(last_block).to eq("#{"a" * 37}\r\n\r\e[2K  #{"a" * 37}\r\n\r\e[2K  #{"a" * 5}")
    end

    it "wraps a wide (CJK) glyph WHOLE to the next row, never split mid-cell" do
      # 36 ASCII chars leave 1 column on row 0; a width-2 glyph can't fit and
      # must open row 1 whole.
      type("#{"a" * 36}中")
      expect(last_block).to eq("#{"a" * 36}\r\n\r\e[2K  中")
    end

    describe "caret math across wrapped rows" do
      it "parks the caret at EOL of the last row with no repositioning bytes" do
        type("a" * 38)
        expect(output.string).to end_with("\r\e[2K  a") # printing ended at the caret
      end

      it "Home (Ctrl+A) walks the caret up to row 0, prompt column" do
        type("a" * 38)
        composer.handle_key("\x01")
        # Park: one row up from the last row, re-home, step right past "❯ ".
        expect(output.string).to end_with("\e[1A\r\e[2C")
      end

      it "End (Ctrl+E) returns the caret to the buffer end on the last row" do
        type("a" * 38)
        composer.handle_key("\x01")
        composer.handle_key("\x05")
        expect(output.string).to end_with("\r\e[2K  a") # EOL again, no repositioning
      end

      it "← across the wrap boundary lands at the hanging-indent column of the continuation row" do
        type("a" * 38) # caret after char 38 (row 1, indent col + 1)
        composer.handle_key("\x02") # Ctrl+B ← : caret at index 37 = row 1, the indent column
        frame = output.string
        expect(frame).to end_with("\r\e[2C") # re-home + step to the hanging indent (P12)
      end

      it "→ from the boundary steps back onto the wrapped char" do
        type("a" * 38)
        composer.handle_key("\x02")
        composer.handle_key("\x06") # Ctrl+F → : caret back to EOL of the indented row
        expect(output.string).to end_with("\r\e[2K  a")
      end

      it "a caret ON a newline stays at the end of the broken row" do
        composer.instance_variable_set(:@input, StringIO.new("[200~ab\ncd\e[201~"))
        composer.handle_key("\e")
        composer.handle_key("\x01") # Home: index 0 (row 0)
        2.times { composer.handle_key("\x06") } # → → : caret at index 2 (the \n)
        # Row 1 below the caret (+ no status): park walks up one row to col 4.
        expect(output.string).to end_with("\e[1A\r\e[4C")
      end
    end

    describe "↑/↓ by visual row vs history" do
      subject(:composer) do
        described_class.new(input_queue: queue, input: input, output: output, history: history)
      end

      let(:history) { Rubino::UI::InputHistory.new(store: ["older entry"]) }

      it "↑ inside a multi-row buffer moves the caret up one visual row, same column" do
        type("a" * 60) # rows: 37 + 23; caret row 1, screen col 25 (indent + 23)
        escape("[A")
        # Row 0 col 25 → 2 prompt cols → buffer index 23. Buffer untouched.
        expect(composer.buffer).to eq("a" * 60)
        expect(composer.instance_variable_get(:@cursor)).to eq(23)
      end

      it "↓ moves back down a visual row, preserving the column" do
        type("a" * 60)
        escape("[A")
        escape("[B")
        expect(composer.instance_variable_get(:@cursor)).to eq(60) # row 1 col 23
        expect(composer.buffer).to eq("a" * 60)
      end

      it "↑ from the FIRST visual row falls back to history" do
        type("a" * 60)
        composer.handle_key("\x01") # Home → first row
        escape("[A")
        expect(composer.buffer).to eq("older entry")
      end

      it "↓ from the LAST visual row falls back to history (restores the draft)" do
        type("a" * 60)
        composer.handle_key("\x01")
        escape("[A") # history: older entry
        escape("[B") # back down: restores the 60-char draft
        expect(composer.buffer).to eq("a" * 60)
      end

      it "↑ in a single-row buffer is history, exactly as before" do
        type("short")
        escape("[A")
        expect(composer.buffer).to eq("older entry")
      end

      it "navigates real newline rows (pasted block) by visual row too" do
        composer.instance_variable_set(:@input, StringIO.new("[200~first\nsecond\e[201~"))
        composer.handle_key("\e") # caret at end of "second" (row 1, screen col 8)
        escape("[A")
        # Row 0, screen column preserved: col 8 clamps to the end of "first" → index 5.
        expect(composer.instance_variable_get(:@cursor)).to eq(5)
        expect(composer.buffer).to eq("first\nsecond")
      end
    end

    describe "growth cap + vertical scroll (max_input_rows)" do
      subject(:composer) do
        described_class.new(input_queue: queue, input: input, output: output, max_input_rows: 3)
      end

      it "shows only the cap's worth of rows, keeping the caret row in view" do
        composer.instance_variable_set(:@input, StringIO.new("[200~r1\nr2\nr3\nr4\nr5\e[201~"))
        composer.handle_key("\e") # 5 logical rows, caret on the last
        block = last_block
        # The window slides to the caret: rows r3..r5 visible, r1/r2 scrolled out.
        expect(block).to include("r3\r\n")
        expect(block).to include("r4\r\n")
        expect(block).to end_with("r5")
        expect(block).not_to include("r1")
        # NOTE: last_block splits on the prompt draw; with the prompt row
        # scrolled out of the window the block starts at the first visible row.
      end

      it "scrolls back up when the caret moves to the top (Home)" do
        composer.instance_variable_set(:@input, StringIO.new("[200~r1\nr2\nr3\nr4\nr5\e[201~"))
        composer.handle_key("\e")
        composer.handle_key("\x01") # Home: caret to index 0 → window follows up
        block = output.string.split("\r\e[2K#{PROMPT}").last
        expect(block).to include("r1\r\n")
        expect(block).to include("r2\r\n")
        expect(block).not_to include("r4")
      end
    end

    it "submit clears ALL rows and the payload keeps its newlines" do
      composer.instance_variable_set(:@input, StringIO.new("[200~l1\nl2\nl3\e[201~"))
      composer.handle_key("\e")
      composer.handle_key("\r")
      expect(queue.drain).to eq(["l1\nl2\nl3"])
      # The post-submit frame walks UP clearing the stale continuation rows
      # (the caret sat on the last row) and redraws a bare one-row prompt.
      expect(output.string).to include("\e[1A\e[2K")
      expect(output.string).to end_with("\r\e[2K#{PROMPT}")
    end

    it "idle Ctrl+C clears a multi-row draft down to a bare one-row prompt" do
      composer.instance_variable_set(:@input, StringIO.new("[200~l1\nl2\nl3\e[201~"))
      composer.handle_key("\e")
      expect(composer.idle_interrupt).to eq(:cleared)
      expect(composer.buffer).to eq("")
      expect(output.string).to end_with("\r\e[2K#{PROMPT}")
    end

    it "re-wraps on resize while multi-row" do
      io = Class.new(StringIO) do
        attr_accessor :cols

        def winsize = [24, cols || 40]
      end.new
      c = described_class.new(input_queue: queue, input: input, output: io)
      "x".ljust(50, "x").each_char { |ch| c.handle_key(ch) } # 2 rows at 40 cols
      io.cols = 60 # row budget 59; 50 + prompt 2 = 52 → fits one row again
      c.resize
      expect(io.string.split("\r\e[2K#{PROMPT}").last).to eq("x" * 50)
    end

    it "print_above while multi-row commits above and redraws the whole block" do
      composer.instance_variable_set(:@input, StringIO.new("[200~l1\nl2\e[201~"))
      composer.handle_key("\e")
      composer.print_above("agent line")
      tail = output.string.split("agent line\r\n").last
      expect(tail).to include("\r\e[2K#{PROMPT}l1\r\n")
      expect(tail).to end_with("l2")
    end
  end

  # The status bar: a dim model + context line pinned BELOW the input row —
  # the live region's last row, redrawn with every frame, updated only at turn
  # boundaries via #set_status.
  describe "status bar (below the input)" do
    subject(:composer) do
      described_class.new(input_queue: queue, input: input, output: output, status_line: status)
    end

    let(:status) { "m1 · ctx 12% · ~8.4k/64k tok" }

    it "draws the bar on the row below the input and parks the caret back on the input row" do
      composer.handle_key("h")
      composer.handle_key("i")
      # Input row, CRLF, status row, then walk back up to the caret (col 4).
      expect(output.string).to end_with("\r\e[2K#{PROMPT}hi\r\n\r\e[2K#{status}\e[1A\r\e[4C")
    end

    it "stays the LAST row under a multi-row input block" do
      composer.instance_variable_set(:@input, StringIO.new("[200~l1\nl2\e[201~"))
      composer.handle_key("\e")
      # Caret at the end of "l2" (indent col + 2); the park walks up past the bar only.
      expect(output.string).to end_with("\r\e[2K#{PROMPT}l1\r\n\r\e[2K  l2\r\n\r\e[2K#{status}\e[1A\r\e[4C")
    end

    it "stays below while committed output scrolls above (print_above)" do
      composer.print_above("agent line")
      s = output.string
      expect(s.index("agent line")).to be < s.index(status)
      expect(s).to end_with("#{status}\e[1A\r\e[2C")
    end

    it "#set_status repaints the bar in place at a turn boundary" do
      composer.handle_key("x")
      composer.set_status("m1 · ctx 47% · ~30k/64k tok")
      # The stale bar row below the caret is walked down + cleared, then redrawn.
      expect(output.string).to include("\e[1B\e[2K")
      expect(output.string).to include("m1 · ctx 47% · ~30k/64k tok")
    end

    it "#set_status(nil) removes the bar row" do
      composer.handle_key("x")
      composer.set_status(nil)
      expect(output.string.split("\r\e[2K#{PROMPT}").last).to eq("x")
    end

    it "no bar is drawn without a status line (default)" do
      c = described_class.new(input_queue: queue, input: input, output: output)
      c.handle_key("x")
      expect(output.string).to end_with("\r\e[2K#{PROMPT}x")
    end

    it "is omitted on a terminal narrower than 40 columns" do
      narrow = Class.new(StringIO) { def winsize = [24, 39] }.new
      c = described_class.new(input_queue: queue, input: input, output: narrow,
                              status_line: status)
      c.handle_key("x")
      expect(narrow.string).not_to include(status)
      expect(narrow.string).to end_with("#{PROMPT}x")
    end

    it "is omitted whole (never truncated mid-ANSI) when wider than the row" do
      c = described_class.new(input_queue: queue, input: input, output: output,
                              status_line: "s" * 60) # 40-col terminal
      c.handle_key("x")
      expect(output.string).not_to include("s" * 10)
      expect(output.string).to end_with("#{PROMPT}x")
    end

    it "measures fit on the ANSI-stripped width (a styled bar that fits is drawn)" do
      styled = "\e[2m#{"s" * 30}\e[0m" # 30 visible cols on a 40-col terminal
      c = described_class.new(input_queue: queue, input: input, output: output,
                              status_line: styled)
      c.handle_key("x")
      expect(output.string).to include(styled)
    end

    it "records the bar in the LiveRegion's below-geometry" do
      composer.handle_key("x")
      region = composer.instance_variable_get(:@region)
      expect(region.input_below).to eq(1)
    end

    # #421 affordance: while a turn is active the status row carries a dim
    # "(esc to interrupt)" hint so the user knows Esc cancels the turn (Enter
    # now queues). It appears on #begin_turn and clears on #end_turn.
    context "type-ahead affordance (#421)" do
      subject(:composer) do
        described_class.new(input_queue: queue, input: input, output: output,
                            status_line: status, on_interrupt: -> {})
      end

      # A SHORT bar so the bar + "  (esc to interrupt)" hint both fit the test's
      # 40-col terminal (a long bar legitimately drops the cosmetic hint — its
      # own example below).
      let(:status) { "m3" }

      it "shows '(esc to interrupt)' in the status row while a turn is active" do
        composer.handle_key("x")
        composer.begin_turn
        expect(output.string).to include("(esc to interrupt)")
      end

      it "clears the hint once the turn ends" do
        composer.handle_key("x")
        composer.begin_turn
        output.truncate(0) # only inspect the post-end_turn repaint
        output.rewind
        composer.end_turn
        expect(output.string).not_to include("(esc to interrupt)")
        expect(output.string).to include("m3") # the bare bar is still drawn
      end

      it "does not show the hint at the idle prompt (no active turn)" do
        composer.handle_key("x")
        expect(output.string).not_to include("(esc to interrupt)")
      end

      it "does not show the hint without an interrupt hook wired" do
        c = described_class.new(input_queue: queue, input: input, output: output,
                                status_line: status) # no on_interrupt
        c.handle_key("x")
        c.begin_turn
        expect(output.string).not_to include("(esc to interrupt)")
      end

      it "drops the cosmetic hint (keeps the bar) when the combined row overflows" do
        c = described_class.new(input_queue: queue, input: input, output: output,
                                status_line: "s" * 30, on_interrupt: -> {}) # 30 + hint > 40
        c.handle_key("x")
        c.begin_turn
        expect(output.string).to include("s" * 30) # bar kept
        expect(output.string).not_to include("(esc to interrupt)") # hint dropped
      end
    end

    it "teardown clears the bar row along with the input block" do
      composer.handle_key("x")
      # Drive the shared #stop/#suspend teardown directly (no live reader).
      composer.instance_variable_get(:@render).synchronize do
        composer.send(:clear_live_region_to_clean_line)
      end
      # The teardown clear walks DOWN over the status row before re-homing.
      expect(output.string).to include("\e[1B\e[2K")
    end
  end

  describe "Esc-Esc double-tap (the rewind chord)" do
    subject(:composer) do
      described_class.new(input_queue: queue, input: input, output: output,
                          completion_source: source, on_double_esc: hook)
    end

    let(:source) { Rubino::UI::CompletionSource.new(commands: %w[/help /reset]) }
    let(:fired)  { [] }
    let(:hook)   { -> { fired << :rewind } }

    # A LONE Esc: the reader sees no following bytes.
    def esc(c)
      c.instance_variable_set(:@input, StringIO.new(""))
      c.handle_key("\e")
    end

    # Pin the monotonic clock the chord measures against.
    def clock_returns(*times)
      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC).and_return(*times)
    end

    it "fires the hook on two lone ESCs within the window at the idle prompt" do
      clock_returns(0.0, 0.2)
      esc(composer)
      expect(fired).to be_empty # first Esc only arms
      esc(composer)
      expect(fired).to eq([:rewind])
    end

    it "does not fire when the second Esc falls outside the window" do
      clock_returns(0.0, 1.0)
      esc(composer)
      esc(composer)
      expect(fired).to be_empty
    end

    it "a late second Esc re-arms: a third within the window still fires" do
      clock_returns(0.0, 1.0, 1.2)
      3.times { esc(composer) }
      expect(fired).to eq([:rewind])
    end

    it "with a menu open the first Esc dismisses AND arms; the second fires" do
      "/re".each_char { |ch| composer.handle_key(ch) }
      expect(composer.menu_open?).to be(true)

      clock_returns(0.0, 0.2)
      esc(composer)
      expect(composer.menu_open?).to be(false) # dismiss kept its meaning
      expect(fired).to be_empty
      esc(composer)
      expect(fired).to eq([:rewind])
    end

    it "never fires during a turn (idle-only), however fast the mash" do
      composer.begin_turn
      clock_returns(0.0, 0.1, 0.2, 0.3, 5.0, 5.1)
      4.times { esc(composer) }
      expect(fired).to be_empty
      composer.end_turn

      2.times { esc(composer) }
      expect(fired).to eq([:rewind]) # idle again — the chord works
    end

    it "never fires while content is streaming" do
      composer.begin_content_stream
      clock_returns(0.0, 0.1)
      2.times { esc(composer) }
      expect(fired).to be_empty
    end

    it "fires when both ESC bytes land in ONE read burst (fast double-tap)" do
      clock_returns(0.0, 0.0)
      composer.instance_variable_set(:@input, StringIO.new("\e")) # the 2nd ESC is the 1st's tail
      composer.handle_key("\e")
      expect(fired).to eq([:rewind])
    end

    it "a one-burst ESC ESC over an open menu dismisses it and fires" do
      "/re".each_char { |ch| composer.handle_key(ch) }
      clock_returns(0.0, 0.0)
      composer.instance_variable_set(:@input, StringIO.new("\e"))
      composer.handle_key("\e")
      expect(composer.menu_open?).to be(false)
      expect(fired).to eq([:rewind])
    end

    it "leaves a Meta-prefixed sequence (ESC ESC [ A) to its real action" do
      composer.handle_key("x")
      composer.instance_variable_set(:@input, StringIO.new("\e[D")) # ESC ESC [ D
      composer.handle_key("\e")
      expect(fired).to be_empty # a Meta-arrow, not the chord
    end

    it "is a quiet no-op without a hook wired (the in-turn composer)" do
      c = described_class.new(input_queue: queue, input: input, output: output)
      expect { 3.times { esc(c) } }.not_to raise_error
    end
  end

  describe "#prefill (Esc-Esc rewind edit-and-resend)" do
    it "replaces the buffer with multiline text and parks the caret at the end" do
      composer.handle_key("d") # a stale draft the prefill replaces
      composer.prefill("fix the spec\nthen rerun")

      expect(composer.buffer).to eq("fix the spec\nthen rerun")
      composer.handle_key("!") # proves the caret sits at the very end
      expect(composer.buffer).to eq("fix the spec\nthen rerun!")
    end

    it "submits the prefilled multiline text intact" do
      composer.prefill("line one\nline two")
      composer.handle_key("\r")
      expect(queue.shift).to eq("line one\nline two")
    end

    it "closes an open completion menu (the text is a message, not a token)" do
      c = described_class.new(
        input_queue: queue, input: input, output: output,
        completion_source: Rubino::UI::CompletionSource.new(commands: %w[/help])
      )
      "/he".each_char { |ch| c.handle_key(ch) }
      expect(c.menu_open?).to be(true)

      c.prefill("try again with --verbose")
      expect(c.menu_open?).to be(false)
      expect(c.buffer).to eq("try again with --verbose")
    end

    it "clears the buffer on nil/empty" do
      composer.prefill("draft")
      composer.prefill(nil)
      expect(composer.buffer).to eq("")
    end
  end

  # #319: a single Esc at the idle prompt cancels the detached post-turn
  # polishing IF the on_escape hook claims it — and only then; otherwise the
  # Esc still falls through to the Esc-Esc rewind arm.
  describe "on_escape (single-Esc polishing cancel)" do
    it "consumes a lone Esc when the hook claims it (cancel polishing)" do
      fired = false
      rewound = false
      c = described_class.new(input_queue: queue, input: input, output: output,
                              on_escape: -> { fired = true },
                              on_double_esc: -> { rewound = true })
      2.times { c.send(:handle_lone_esc) } # two lone Escs within the window

      # The first Esc was consumed by on_escape (polishing cancel), so the
      # rewind chord never armed/fired — even on the second Esc.
      expect(fired).to be(true)
      expect(rewound).to be(false)
    end

    it "falls through to the rewind chord when on_escape declines (nothing to cancel)" do
      rewound = false
      c = described_class.new(input_queue: queue, input: input, output: output,
                              on_escape: -> {}, # nothing in flight (falsy)
                              on_double_esc: -> { rewound = true })
      2.times { c.send(:handle_lone_esc) }

      expect(rewound).to be(true)
    end
  end
end
