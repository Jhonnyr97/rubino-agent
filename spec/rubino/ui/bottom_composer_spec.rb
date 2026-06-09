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
      # avail = 40 - PROMPT.length - 1. Type more than that. The cursor is at the
      # end, so the scroll-window keeps the tail in view with a leading "…"; the
      # frame then re-homes (\r) and steps the caret right to park it. Read the
      # VISIBLE segment (prompt + window) before that caret re-home.
      50.times { |i| composer.handle_key((97 + (i % 26)).chr) }
      last_frame = output.string.split("\r\e[2K").last
      visible = last_frame.split("\r").first.sub(PROMPT, "")
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

    # echo: :prompt is the IDLE submit (the line IS the user's message): the
    # submitted line commits ABOVE the pinned prompt as "<prompt><line>", reading
    # back like a normal shell submit rather than the "queued ▸" steering marker.
    context "with echo: :prompt (idle path)" do
      subject(:composer) do
        described_class.new(input_queue: queue, input: input, output: output,
                            prompt: "default ❯ ", echo: :prompt)
      end

      it "echoes the submitted line above the prompt as <prompt><line>" do
        "hi".each_char { |c| composer.handle_key(c) }
        composer.handle_key("\r")
        expect(output.string).to include("default ❯ hi\r\n")
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
        expect(output.string).to include("default ❯ hi\r\n")
      end
    end

    # NEW MODEL: Enter while a turn is active INTERRUPTS the current turn and
    # sends the line as the NEXT turn immediately (the default). The line is
    # pushed to the queue AND the on_interrupt hook fires; nothing is echoed
    # here (the next turn's prompt echo is committed by the chat loop when it
    # runs). The OLD "queued ▸" deferred echo is retired.
    context "interrupt-by-default (Enter during an active turn)" do
      it "fires on_interrupt and queues the line, with no echo, during streaming" do
        interrupts = 0
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> { interrupts += 1 })
        c.begin_turn
        c.begin_content_stream
        "ping".each_char { |ch| c.handle_key(ch) }
        c.handle_key("\r")
        expect(interrupts).to eq(1)            # interrupt fired exactly once
        expect(queue.drain).to eq(["ping"])    # line queued for the immediate next run
        expect(output.string).not_to include("queued ▸") # old deferred echo retired
        expect(output.string).not_to include("⏳ queued") # not an explicit queue either
      end

      it "fires on_interrupt during the THINKING phase too (turn active, not streaming)" do
        interrupts = 0
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> { interrupts += 1 })
        c.begin_turn # NO begin_content_stream yet (thinking)
        "while-thinking".each_char { |ch| c.handle_key(ch) }
        c.handle_key("\r")
        expect(interrupts).to eq(1)
        expect(queue.drain).to eq(["while-thinking"])
        expect(output.string).not_to include("queued ▸")
      end

      # end_turn is now a quiet no-op (no deferred echoes to flush).
      it "emits nothing at turn end (deferred-echo machinery retired)" do
        c = described_class.new(input_queue: queue, input: input, output: output,
                                on_interrupt: -> {})
        c.begin_turn
        "x".each_char { |ch| c.handle_key(ch) }
        c.handle_key("\r")
        before = output.string.dup
        c.end_turn
        expect(output.string).to eq(before) # nothing flushed at turn end
      end
    end

    # EXPLICIT QUEUE (the exception): Alt+Enter (\e\r) or "/queued <msg>" queues
    # WITHOUT interrupting — the current turn keeps running. The queued message
    # shows a live "⏳ queued: <msg>" row above the input while pending; it's
    # removed and committed as a normal message when its turn runs (#commit_queued).
    context "explicit queue (Alt+Enter / /queued)" do
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
        expect(c.buffer).to eq("")                # buffer cleared
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
                                 prompt: "default ❯ ", echo: :prompt, pending_queued: pending)
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
    let(:store) { [] }
    subject(:composer) do
      described_class.new(input_queue: queue, input: input, output: output,
                          history: Rubino::UI::InputHistory.new(store: store))
    end

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
    let(:source) do
      Rubino::UI::CompletionSource.new(commands: %w[/help /exit /reasoning /reset])
    end
    subject(:composer) do
      described_class.new(input_queue: queue, input: input, output: output,
                          completion_source: source)
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
      expect(composer.menu_open?).to be(false)         # dismiss stuck — no pop-back
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
      expect(c.instance_variable_get(:@menu)[:items]).to eq(%w[@src/b.rb])
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

  describe "#handle_key Shift+Tab (mode cycle)" do
    # Shift+Tab arrives as ESC[Z: preload the bytes after ESC, then trigger the
    # escape consumer via handle_key("\e") — the same way the paste specs drive it.
    it "invokes on_mode_cycle and adopts the returned prompt chip" do
      cycles = 0
      io = StringIO.new("[Z")
      c = described_class.new(input_queue: queue, input: io, output: output,
                              on_mode_cycle: -> { cycles += 1; "yolo ❯ " })
      c.handle_key("\e")
      expect(cycles).to eq(1)
      expect(output.string).to include("yolo ❯ ") # the new chip was redrawn
    end

    it "is a quiet no-op when no callback is wired" do
      io = StringIO.new("[Z")
      expect { composer.handle_key("\e"); composer.send(:read_nonblock_char) }.not_to raise_error
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
      output.truncate(0); output.rewind
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

  describe "bracketed paste (L1)" do
    # Drive a paste by preloading the input IO with the bytes that follow the
    # initial ESC, then triggering the escape consumer via handle_key("\e").
    def paste(body)
      io = StringIO.new("[200~#{body}\e[201~")
      c  = described_class.new(input_queue: queue, input: io, output: output)
      c.handle_key("\e")
      c
    end

    # D6: the one-row composer collapses a multi-line paste into a single
    # editable line, joining lines with a SPACE so adjacent words don't fuse
    # (the "word1word2" defect) and a literal newline never desyncs the row. The
    # paste is NOT auto-submitted — it lands in the buffer, editable.
    it "collapses a multi-line paste into one editable line joined by spaces (D6)" do
      c = paste("line1\nline2\nline3")
      expect(queue.drain).to eq([]) # not auto-submitted
      expect(c.buffer).to eq("line1 line2 line3")
    end

    it "does not glue words across pasted lines (D6 separator)" do
      c = paste("first paragraph\nsecond paragraph")
      expect(c.buffer).to include(" ")
      expect(c.buffer).not_to include("paragraphsecond")
      expect(c.buffer).to eq("first paragraph second paragraph")
    end

    it "normalizes CR / CRLF pasted line breaks to a single space (D6)" do
      expect(paste("a\r\nb").buffer).to eq("a b")
      expect(paste("a\rb").buffer).to eq("a b")
    end

    it "collapses a run of blank lines to a single space (no wall of spaces)" do
      expect(paste("a\n\n\nb").buffer).to eq("a b")
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
      expect(c.buffer).to eq("aX Yc")
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
