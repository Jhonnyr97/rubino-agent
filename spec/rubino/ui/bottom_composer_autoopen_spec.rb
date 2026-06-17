# frozen_string_literal: true

require "stringio"

# Unit specs for the MID-TURN AUTO-OPEN concurrency primitives on the bottom
# composer (the ask_parent dropdown that opens by itself while the parent turn
# is still streaming). These drive the composer directly — no PTY — and pin the
# three load-bearing guarantees:
#
#   * R1 write-park: a committed stream line (#print_above) that arrives WHILE
#     the composer is suspended for the dropdown is BUFFERED, not painted raw
#     over the dropdown, and FLUSHED in order when the takeover ends.
#   * draft preservation: the in-progress @buffer + @cursor are snapshotted at
#     request time and restored BYTE-FOR-BYTE after the dropdown closes; keys
#     consumed by the dropdown never mutate the draft.
#   * the request→input-thread handoff state machine (request_takeover queues a
#     block + snapshot; run_pending_takeover runs it, restores, and leaves
#     takeover mode flushing the parked writes).
RSpec.describe Rubino::UI::BottomComposer do
  # A StringIO that also answers #winsize so the composer's width math is
  # deterministic without a real terminal. Stubbed (not a top-level constant) to
  # avoid leaking/redefining the class another composer spec already declares.
  subject(:composer) do
    described_class.new(input_queue: queue, input: input, output: output)
  end

  let(:term_io_class) do
    Class.new(StringIO) do
      def winsize = [24, 80]
    end
  end
  let(:queue)  { Rubino::Interaction::InputQueue.new }
  let(:output) { term_io_class.new }
  let(:input)  { StringIO.new }

  def cursor = composer.instance_variable_get(:@cursor)
  def suspended? = composer.instance_variable_get(:@suspended)
  def parked = composer.instance_variable_get(:@parked_writes)

  describe "R1 write-park (#print_above while suspended)" do
    it "BUFFERS committed stream lines while suspended instead of painting them" do
      composer.enter_takeover_mode # flips @suspended without touching the (unstarted) reader
      before = output.string.dup

      composer.print_above("streamed line A")
      composer.print_above("streamed line B")

      # Nothing painted to the terminal during the suspend window …
      expect(output.string).to eq(before)
      # … the lines are parked in arrival order instead.
      expect(parked).to eq(["streamed line A", "streamed line B"])
    end

    it "FLUSHES the parked lines in order, then redraws, when takeover mode is left" do
      composer.enter_takeover_mode
      composer.print_above("first")
      composer.print_above("second")

      composer.leave_takeover_mode

      out = output.string
      expect(out).to include("first").and include("second")
      expect(out.index("first")).to be < out.index("second") # arrival order preserved
      expect(parked).to be_nil # buffer drained
      expect(suspended?).to be(false)
    end

    it "paints #print_above immediately when NOT suspended (unchanged behaviour)" do
      composer.print_above("live line")
      expect(output.string).to include("live line")
      expect(parked).to be_nil
    end
  end

  describe "draft snapshot + restore across a takeover" do
    it "restores the EXACT draft + cursor after a takeover that consumed keys" do
      # Type a draft and park the cursor mid-line (not at the end).
      "ciao mondo".each_char { |c| composer.handle_key(c) }
      composer.handle_key("\x01") # Ctrl+A → cursor to start
      composer.handle_key("\x06") # Ctrl+F → cursor at index 1
      expect(composer.buffer).to eq("ciao mondo")
      expect(cursor).to eq(1)

      # Queue a takeover whose block simulates the dropdown editing the buffer
      # (as a leaked keystroke WOULD) — the snapshot must override it.
      ran = false
      composer.instance_variable_set(:@running, true)
      composer.instance_variable_set(:@wake_pipe, StringIO.new) # satisfy the guard
      expect(composer.request_takeover do
        ran = true
        composer.prefill("DROPDOWN CORRUPTION") # the dropdown must NOT leak into the draft
      end).to be(true)

      composer.run_pending_takeover

      expect(ran).to be(true)
      expect(composer.buffer).to eq("ciao mondo") # byte-for-byte
      expect(cursor).to eq(1)                     # caret restored
      expect(suspended?).to be(false)             # takeover mode left
    end

    it "snapshots the draft AT REQUEST TIME (a later edit can't tear it)" do
      "abc".each_char { |c| composer.handle_key(c) }
      composer.instance_variable_set(:@running, true)
      composer.instance_variable_set(:@wake_pipe, StringIO.new)

      composer.request_takeover { nil }
      # An edit AFTER the snapshot was taken is discarded on restore.
      composer.prefill("xyz123")

      composer.run_pending_takeover
      expect(composer.buffer).to eq("abc")
      expect(cursor).to eq(3)
    end
  end

  describe "in-flight keystrokes pending in the TTY queue at takeover time" do
    # The HEADLINE bug: the human is actively mid-typing when the dropdown
    # auto-opens. The bytes already in the kernel TTY queue (typed but not yet
    # read into @buffer by the reader, which broke its loop on the wake pipe
    # WITHOUT a getc) must be DRAINED INTO the draft before the dropdown reads
    # $stdin — never leak into the picker's filter and never leave the draft
    # short. We simulate the in-flight bytes by leaving them unread on @input
    # when request_takeover fires.

    it "drains StringIO-queued bytes INTO the draft; picker filter gets none" do
      "sto scrivendo una ".each_char { |c| composer.handle_key(c) }
      expect(composer.buffer).to eq("sto scrivendo una ")

      # Bytes still queued (typed but un-getc'd) when the auto-open races in.
      input.string = "doman"
      input.rewind

      composer.instance_variable_set(:@running, true)
      composer.instance_variable_set(:@wake_pipe, StringIO.new)

      leaked = +""
      composer.request_takeover { leaked << input.read.to_s }
      composer.run_pending_takeover

      # The draft is COMPLETE (in-flight bytes drained in) …
      expect(composer.buffer).to eq("sto scrivendo una doman")
      expect(cursor).to eq("sto scrivendo una doman".length)
      # … and NOTHING leaked into the picker's filter.
      expect(leaked).to eq("")
    end

    it "drains a real-pipe TTY queue via the select(0) gate without blocking" do
      reader, writer = IO.pipe
      pipe_composer = described_class.new(input_queue: queue, input: reader, output: output)
      "ciao ".each_char { |c| pipe_composer.handle_key(c) }

      # In-flight bytes sitting in the kernel pipe buffer, unread.
      writer.write("mondo")

      pipe_composer.instance_variable_set(:@running, true)
      pipe_composer.instance_variable_set(:@wake_pipe, StringIO.new)

      leaked = +""
      pipe_composer.request_takeover do
        # Whatever the drain left behind is what the picker would see.
        leaked << reader.read_nonblock(64) if reader.wait_readable(0)
      end
      pipe_composer.run_pending_takeover

      expect(pipe_composer.buffer).to eq("ciao mondo")
      expect(leaked).to eq("") # the select-gated drain emptied the queue first
    ensure
      reader.close unless reader.closed?
      writer.close unless writer.closed?
    end

    it "drains nothing (no block) when the TTY queue is empty at takeover time" do
      "hola".each_char { |c| composer.handle_key(c) }
      composer.instance_variable_set(:@running, true)
      composer.instance_variable_set(:@wake_pipe, StringIO.new)

      composer.request_takeover { nil }
      composer.run_pending_takeover # must return promptly, draft intact

      expect(composer.buffer).to eq("hola")
      expect(cursor).to eq(4)
    end
  end

  describe "#request_takeover guards (one at a time)" do
    before do
      composer.instance_variable_set(:@running, true)
      composer.instance_variable_set(:@wake_pipe, StringIO.new)
    end

    it "is a no-op when not running" do
      composer.instance_variable_set(:@running, false)
      expect(composer.request_takeover { nil }).to be(false)
    end

    it "is a no-op when already suspended" do
      composer.instance_variable_set(:@suspended, true)
      expect(composer.request_takeover { nil }).to be(false)
    end

    it "drops a SECOND request while one is already pending (FIFO re-read gets it)" do
      expect(composer.request_takeover { nil }).to be(true)
      expect(composer.request_takeover { nil }).to be(false) # one at a time
    end
  end

  # REGRESSION: the auto-open trigger must RE-ARM for every human-directed ask,
  # not fire one-shot per session. The dropdown a takeover runs calls
  # @ui.select/@ui.ask, which wrap themselves in BottomComposer.run_in_terminal;
  # its ensure fires #suspend then #resume. Before the fix, that nested #resume
  # — gated only on @suspended, which the reader-thread takeover had set — ran
  # leave_takeover_mode + start_reader, spawning a SECOND reader and reassigning
  # @wake_pipe MID-takeover, so the next ask's wake landed on a torn reader and
  # the dropdown never auto-opened again. The fix neuters the nested
  # suspend/resume while @in_takeover, so the takeover restores cleanly and the
  # trigger re-arms.
  describe "re-arm across a takeover whose dropdown nests run_in_terminal" do
    before do
      composer.instance_variable_set(:@running, true)
      composer.instance_variable_set(:@wake_pipe, StringIO.new)
      described_class.current = composer
    end

    after { described_class.current = nil }

    it "does NOT spawn a second reader / leave the composer suspended" do
      # The reader was never started in this unit (@reader stays nil); the only
      # thing that could set it is the spurious nested #resume → #start_reader.
      composer.request_takeover do
        # exactly what @ui.select/@ui.ask do mid-takeover
        described_class.run_in_terminal { :answered }
      end
      composer.run_pending_takeover

      expect(composer.instance_variable_get(:@reader)).to be_nil         # no spurious reader
      expect(suspended?).to be(false)                                    # cleanly restored
      expect(composer.instance_variable_get(:@in_takeover)).to be(false) # guard cleared
    end

    it "ACCEPTS and runs a SECOND takeover after the first (every ask re-arms)" do
      ran = 0
      first = composer.request_takeover do
        ran += 1
        described_class.run_in_terminal { :answered } # nested, as the real dropdown does
      end
      expect(first).to be(true)
      composer.run_pending_takeover
      expect(ran).to eq(1)

      # The SECOND human-directed ask, after the first resolved, must auto-open
      # again — not be silently dropped (the one-shot-per-session defect).
      second = composer.request_takeover { ran += 1 }
      expect(second).to be(true)
      composer.run_pending_takeover
      expect(ran).to eq(2)
    end
  end
end
