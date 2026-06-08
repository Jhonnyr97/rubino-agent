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

  let(:queue)  { Rubino::Interaction::InputQueue.new }
  let(:output) { FakeTermIO.new }
  # A fake input that is "not a tty" so #start's cooked!/raw paths stay inert
  # when a test constructs but never starts.
  let(:input)  { StringIO.new }

  subject(:composer) do
    described_class.new(input_queue: queue, input: input, output: output)
  end

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

    it "truncates a buffer wider than the row with a leading ellipsis" do
      # avail = 40 - PROMPT.length - 1. Type more than that.
      50.times { |i| composer.handle_key((97 + (i % 26)).chr) }
      last_frame = output.string.split("\r\e[2K").last
      visible = last_frame.sub(PROMPT, "")
      expect(visible.length).to be <= 40 - PROMPT.length - 1 + 1 # incl. the "…"
      expect(visible).to start_with("…")
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

    it "submits a multi-line paste as ONE message with newlines preserved" do
      paste("line1\nline2\nline3")
      expect(queue.drain).to eq(["line1\nline2\nline3"])
    end

    it "does not glue words across pasted lines" do
      paste("first paragraph\nsecond paragraph")
      drained = queue.drain.first
      expect(drained).to include("\n")
      expect(drained).not_to include("paragraphsecond")
    end

    it "preserves CR-delimited pasted newlines (normalized to \\n)" do
      paste("a\r\nb")
      expect(queue.drain).to eq(["a\nb"])
    end

    it "appends a single-line paste to the editable buffer (not auto-submitted)" do
      c = paste("inline text")
      expect(queue.drain).to eq([])
      expect(c.buffer).to eq("inline text")
    end

    it "echoes a compact multi-line marker above the prompt" do
      paste("alpha\nbeta\ngamma")
      expect(output.string).to match(/queued ▸ alpha .*\(3 lines pasted\)/)
    end
  end

  describe "#print_above" do
    it "erases the input line, writes the output, then redraws the input" do
      composer.handle_key("h")
      composer.handle_key("i")
      output.truncate(0); output.rewind
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

    it "an empty argument just repaints the prompt" do
      composer.handle_key("x")
      output.truncate(0); output.rewind
      composer.print_above("")
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
      output.truncate(0); output.rewind
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
      output.truncate(0); output.rewind
      composer.resize
      expect(output.string).to end_with("#{PROMPT}z")
    end

    it "repaints the live streamed partial on resize so mid-stream output isn't wiped (X1)" do
      composer.set_partial("streaming answer in progress")
      output.truncate(0); output.rewind
      composer.resize
      # The partial text is re-emitted (not left blank until the turn commits).
      expect(output.string).to include("streaming answer in progress")
      # The prompt is redrawn below it.
      expect(output.string).to end_with(PROMPT)
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

    subject(:composer) do
      described_class.new(input_queue: queue, input: read_io, output: output)
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
      first = true
      allow(IO).to receive(:select).and_wrap_original do |orig, ios, *rest|
        if first && ios.length == 2
          first = false
          [ios, [], []] # both readable simultaneously
        else
          orig.call(ios, *rest)
        end
      end

      composer.start
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
      result = described_class.run_in_terminal { yielded = true; :done }
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
  end
end
