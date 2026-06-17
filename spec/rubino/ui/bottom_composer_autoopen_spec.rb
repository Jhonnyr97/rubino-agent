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
end
