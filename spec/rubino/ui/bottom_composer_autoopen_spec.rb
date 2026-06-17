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

    # RESIDUAL B: keystrokes the human types DURING the suspend transition — after
    # the request-time drain snapshot, but before the picker grabs $stdin — must
    # still be captured into the draft (the FINAL drain just before the block), not
    # leak into the picker's filter. We simulate "typed during the transition" by
    # enqueuing more bytes from inside #enter_takeover_mode (which runs between the
    # first drain and the final drain).
    it "captures bytes that ARRIVE during the suspend transition into the draft (not the picker)" do
      # A composer that simulates the human typing DURING the suspend transition:
      # #enter_takeover_mode (which runs BETWEEN the request-time drain and the
      # final pre-picker drain) enqueues more bytes onto @input, exactly as a
      # mid-keystroke human would land them in the kernel TTY queue then.
      transition_io = StringIO.new
      racey = Class.new(described_class) do
        def initialize(*, transition_bytes:, transition_io:, **kwargs)
          super(*, **kwargs)
          @transition_bytes = transition_bytes
          @transition_io    = transition_io
        end

        def enter_takeover_mode
          super
          @transition_io.string = @transition_bytes
          @transition_io.rewind
        end
      end.new(input_queue: queue, input: transition_io, output: output,
              transition_bytes: "ancora", transition_io: transition_io)

      "sto scrivendo ".each_char { |c| racey.handle_key(c) }
      racey.instance_variable_set(:@running, true)
      racey.instance_variable_set(:@wake_pipe, StringIO.new)

      leaked = +""
      racey.request_takeover { leaked << transition_io.read.to_s } # what the picker WOULD see
      racey.run_pending_takeover

      # The transition-arrived bytes were drained INTO the draft …
      expect(racey.buffer).to eq("sto scrivendo ancora")
      # … and the picker filter received NONE of them.
      expect(leaked).to eq("")
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

    # #486: two human-asks that arrive NEAR-SIMULTANEOUSLY (the 2nd lands while
    # the 1st takeover's dropdown is mid-run — after run_pending_takeover cleared
    # @pending_takeover but before the dropdown resolved) must NOT spawn a SECOND
    # overlapping takeover loop. The @takeover_active guard rejects the 2nd while
    # the 1st is running; the FIFO re-read surfaces it after.
    it "REJECTS a second ask that races in BEFORE the first suspends (#486)" do
      described_class.current = composer
      second_accepted = nil
      second_runs = 0

      # The race window the @takeover_active guard closes: #run_pending_takeover
      # has already cleared @pending_takeover but has NOT yet suspended (it is in
      # #drain_inflight_into_draft). A second child blocking on the human RIGHT
      # there would slip past the @pending_takeover / @suspended guards. Fire it
      # from inside the drain to land in exactly that window.
      allow(composer).to receive(:drain_inflight_into_draft).and_wrap_original do |orig, *args|
        second_accepted = composer.request_takeover { second_runs += 1 }
        orig.call(*args)
      end

      composer.request_takeover { nil }
      composer.run_pending_takeover

      expect(second_accepted).to be(false) # one dropdown loop at a time — no overlap
      expect(second_runs).to eq(0)         # the second loop never ran concurrently
    ensure
      described_class.current = nil
    end

    it "REJECTS a second ask that arrives WHILE the dropdown is open (#486)" do
      described_class.current = composer
      second_accepted = nil

      composer.request_takeover do
        # The dropdown is open now (composer suspended). A second child blocking
        # here must NOT spawn an overlapping loop.
        second_accepted = composer.request_takeover { nil }
      end
      composer.run_pending_takeover

      expect(second_accepted).to be(false)
    ensure
      described_class.current = nil
    end

    it "ACCEPTS the deferred ask once the first takeover has fully resolved (#486)" do
      described_class.current = composer
      runs = 0

      composer.request_takeover { runs += 1 } # the first ask
      composer.run_pending_takeover
      expect(runs).to eq(1)

      # The guard is released after the first resolves, so the sibling that was
      # dropped during the dropdown now surfaces on the reader's next session.
      expect(composer.instance_variable_get(:@takeover_active)).to be(false)
      expect(composer.request_takeover { runs += 1 }).to be(true)
      composer.run_pending_takeover
      expect(runs).to eq(2)
    ensure
      described_class.current = nil
    end
  end

  # #486 (Esc names the right child): the auto-open FIFO drain shows the CURRENT
  # head and binds the cancel/"still waiting" message to the entry actually being
  # shown — not an already-answered sibling. With the overlap removed, each pass
  # re-reads awaiting_human.first, so the dropdown and its cancel message are
  # always the same entry. This pins the handler-level binding directly.
  describe "Esc-cancel binds the message to the OPEN child (#486)" do
    let(:registry) { Rubino::Tools::BackgroundTasks.instance }

    def blocked(id)
      Struct.new(:id, :subagent, :status, :ask_question, :ask_options,
                 keyword_init: true).new(
                   id: id, subagent: "explore", status: :blocked_on_human,
                   ask_question: "q?", ask_options: []
                 )
    end

    it "names the child being shown, not a sibling, on a cancelled answer" do
      messages = []
      # A minimal UI: it has #info and #ask but NOT #select, so the free-text
      # path runs and a blank #ask answer reads as a cancel.
      ui = Object.new
      ui.define_singleton_method(:info) { |m| messages << m }
      ui.define_singleton_method(:ask) { |_prompt| "" } # Esc / blank == cancel

      handler = Rubino::Commands::Handlers::Agents.new(ui: ui)
      handler.send(:answer_one_human, blocked("sa_OPEN"))

      cancel = messages.find { |m| m.include?("still waiting") }
      expect(cancel).to include("sa_OPEN")
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

  # RESIDUAL A: the aggregated `⛔N subagents waiting on you` count was UNIT-green
  # (SubagentCards#hint_line computes it) but never actually surfaced — the
  # auto-open takeover suspended the live region (clearing the cards) and resume
  # only redrew the prompt, so the count vanished for the rest of the turn
  # whenever a child stayed awaiting_human (several pending, or the human
  # cancelled). The fix repaints the cards from the live registry on resume.
  # #485: a running-subagent card repaint must NOT disturb the idle composer
  # input. The repaint serializes under @render (so it can't tear an in-flight
  # keystroke) AND coalesces — an UNCHANGED card list is a no-op, so the idle
  # ticker / per-event pokes don't re-run the clear→redraw cursor walk over the
  # live region (the source of the dropped/garbled keystrokes + wedged submit on
  # a real terminal). The CHANGED repaint still paints.
  describe "card repaint does not clobber idle composer input (#485)" do
    it "PRESERVES the buffer + cursor across a card repaint, and Enter still submits" do
      "exit".each_char { |c| composer.handle_key(c) }
      composer.set_cards(["  ▸ sa_1 · explore · running · 3 tools · 5s"])
      expect(composer.buffer).to eq("exit")
      expect(cursor).to eq(4)

      # the repaint did not wedge submit
      expect(composer.handle_key("\r")).to eq(:submit)
      expect(queue.shift).to eq("exit")
    end

    it "PRESERVES a keystroke typed BETWEEN two repaints (no drop/garble)" do
      composer.set_cards(["  ▸ sa_1 · running · 1s"])
      "ex".each_char { |c| composer.handle_key(c) }
      composer.set_cards(["  ▸ sa_1 · running · 2s"]) # repaint with new elapsed
      "it".each_char { |c| composer.handle_key(c) }
      composer.set_cards(["  ▸ sa_1 · running · 3s"])
      expect(composer.buffer).to eq("exit")
    end

    it "COALESCES an UNCHANGED repaint into a no-op (no extra frame to race input)" do
      composer.set_cards(["  ▸ sa_1 · running · 5s"])
      before = output.string.dup
      composer.set_cards(["  ▸ sa_1 · running · 5s"]) # identical rows
      expect(output.string).to eq(before) # nothing re-emitted
    end

    it "still REPAINTS when the cards actually change" do
      composer.set_cards(["  ▸ sa_1 · running · 5s"])
      before = output.string.length
      composer.set_cards(["  ▸ sa_1 · running · 6s"]) # changed elapsed
      expect(output.string.length).to be > before
    end
  end

  describe "aggregated ⛔N count actually PAINTS to the live region (#475-A)" do
    # A minimal blocked-child entry the real SubagentCards formatter consumes.
    def blocked_entry(id)
      Struct.new(:id, :subagent, :status, :ask_question, :tool_count,
                 :started_at, :finished_at, :last_activity, :approval_command,
                 :approval_question, keyword_init: true).new(
                   id: id, subagent: "explore", status: :blocked_on_human,
                   ask_question: "sqlite or postgres?", tool_count: 0
                 )
    end

    def card_lines(*ids)
      Rubino::UI::SubagentCards.new.card_lines(ids.map { |i| blocked_entry(i) })
    end

    it "EMITS the ⛔N hint line to the terminal when a human-ask is registered mid-turn" do
      # set_subagent_cards → set_cards on the live (un-suspended) composer: the
      # count must be written to output, not merely computed.
      composer.set_cards(card_lines("sa_1"))
      expect(output.string).to include("⛔1 subagent waiting on you")
    end

    it "PLURALIZES and paints the aggregate when several children are blocked" do
      composer.set_cards(card_lines("sa_1", "sa_2", "sa_3"))
      expect(output.string).to include("⛔3 subagents waiting on you")
    end

    it "RE-EMITS the ⛔N hint after a takeover resume (it was wiped on suspend)" do
      composer.instance_variable_set(:@running, true)
      composer.instance_variable_set(:@wake_pipe, StringIO.new)

      # Two children blocked; the takeover answers one, leaving ONE still waiting.
      # The on_resume hook is what the CLI registers (set_subagent_cards); here it
      # repaints from the post-answer registry shape (one child left).
      remaining = ["sa_2"]
      composer.request_takeover(on_resume: -> { composer.set_cards(card_lines(*remaining)) }) do
        # the dropdown delivered sa_1's answer while suspended; the live-region
        # repaint it tried then was DROPPED (composer suspended) — the defect.
        composer.set_cards(card_lines("sa_2")) # no-op while suspended
      end

      before_resume = output.string.dup
      composer.run_pending_takeover

      painted = output.string[before_resume.length..]
      # The aggregate for the STILL-blocked child comes back after resume …
      expect(painted).to include("⛔1 subagent waiting on you")
      expect(suspended?).to be(false)
    end

    it "does NOT fire a stale resume hook on a later hook-less takeover" do
      composer.instance_variable_set(:@running, true)
      composer.instance_variable_set(:@wake_pipe, StringIO.new)

      calls = 0
      composer.request_takeover(on_resume: -> { calls += 1 }) { nil }
      composer.run_pending_takeover
      expect(calls).to eq(1)

      # A subsequent takeover with NO hook must not re-run the previous one.
      composer.request_takeover { nil }
      composer.run_pending_takeover
      expect(calls).to eq(1)
    end
  end
end
