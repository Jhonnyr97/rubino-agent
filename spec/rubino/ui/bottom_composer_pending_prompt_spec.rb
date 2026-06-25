# frozen_string_literal: true

require "stringio"

# BUG 01 — mid-turn input mis-routing. While a turn streams, the composer's
# reader parks typed lines into the type-ahead InputQueue (shown with a "⏳
# queued:" indicator) AND a clarification/approval prompt can open mid-turn.
# Before the fix the prompt read $stdin with no knowledge of the queue, so a
# line parked the instant the prompt opened was invisible to it (it fired as a
# stray NEW turn afterwards — Symptom C) and in-flight keystrokes leaked into
# the picker's filter (Symptom B).
#
# These specs drive the reconciliation seam directly (no PTY, no live LLM):
#   * BottomComposer#take_pending_for_prompt — drains in-flight bytes + (opt)
#     the oldest queue line, returns the prefill string;
#   * BottomComposer.run_in_terminal_with_pending — the class-method UI::CLI#ask
#     / #confirm wrap the prompt in.
RSpec.describe Rubino::UI::BottomComposer do
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

  describe "#take_pending_for_prompt (consume_queue: true — the ask/clarification path)" do
    it "DELIVERS a queued line to the prompt instead of leaving it queued (Symptom C)" do
      queue.push("sqlite") # a line parked while the turn streamed

      pending = composer.take_pending_for_prompt(consume_queue: true)

      expect(pending).to eq("sqlite")     # delivered to the prompt as the answer
      expect(queue.pending?).to be(false) # NOT left to fire as a later turn
    end

    it "drains in-flight kernel bytes INTO the prefill (no leak into the picker)" do
      input.string = "doman" # typed but un-read when the prompt opened
      input.rewind

      pending = composer.take_pending_for_prompt(consume_queue: true)

      expect(pending).to eq("doman")
      expect(input.read).to eq("") # the picker would see nothing left
    end

    it "joins a queued line and in-flight typing into one editable prefill" do
      queue.push("post")
      input.string = "gres"
      input.rewind

      # queued head, then the in-flight bytes — the human edits/confirms with Enter.
      expect(composer.take_pending_for_prompt(consume_queue: true)).to eq("post gres")
    end

    it "STOPS the in-flight drain at the first newline (the implicit submit)" do
      input.string = "yes\nleftover"
      input.rewind

      expect(composer.take_pending_for_prompt(consume_queue: true)).to eq("yes")
      expect(input.read).to eq("leftover") # bytes after the newline are untouched
    end

    it "drops control bytes from the in-flight drain (only printable prefill)" do
      input.string = "a\x01b\x04c"
      input.rewind

      expect(composer.take_pending_for_prompt(consume_queue: true)).to eq("abc")
    end

    it "returns nil when nothing is pending (prompt reads $stdin as before)" do
      expect(composer.take_pending_for_prompt(consume_queue: true)).to be_nil
    end

    it "clears the queued line's '⏳ queued:' indicator when it is consumed" do
      composer.send(:queue_message, "sqlite") # both queues AND shows the indicator
      expect(composer.instance_variable_get(:@queued).rows).not_to be_empty

      composer.take_pending_for_prompt(consume_queue: true)

      expect(composer.instance_variable_get(:@queued).rows).to be_empty
    end

    it "takes the OLDEST queued line first (FIFO), leaving the rest queued" do
      queue.push("first")
      queue.push("second")

      expect(composer.take_pending_for_prompt(consume_queue: true)).to eq("first")
      expect(queue.shift).to eq("second") # the rest still run as their own turns
    end
  end

  describe "NO REGRESSION — Symptom A still works (queue + consume as next turn)" do
    it "still parks a mid-turn submit under a '⏳ queued:' indicator and drains it as the next turn" do
      composer.begin_turn # @turn_active — a mid-turn submit must QUEUE, not interrupt
      "ciao".each_char { |c| composer.handle_key(c) }
      composer.handle_key("\r") # Enter while the turn is active

      # Parked behind a live indicator, NOT consumed by any open prompt …
      expect(composer.instance_variable_get(:@queued).rows).not_to be_empty
      expect(queue.pending?).to be(true)
      # … and drained as the next turn exactly as before (no prompt was open, so
      # #take_pending_for_prompt was never called).
      expect(queue.shift).to eq("ciao")
    end
  end

  describe "#take_pending_for_prompt (consume_queue: false — the approval/select path)" do
    it "DRAINS in-flight bytes so they can't leak into the menu filter (Symptom B)" do
      input.string = "/status" # a stray token that would filter the menu to empty
      input.rewind

      composer.take_pending_for_prompt(consume_queue: false)

      expect(input.read).to eq("") # the picker's filter receives none of it
    end

    it "LEAVES a queued line in place (a destructive approval is never auto-filled)" do
      queue.push("yes")

      result = composer.take_pending_for_prompt(consume_queue: false)

      expect(result).to be_nil           # nothing prefilled into the menu
      expect(queue.shift).to eq("yes")   # the line stays queued (runs as next turn)
    end
  end

  describe ".run_in_terminal_with_pending" do
    # A SEPARATE composer (not the `subject`) registered as current, so we can
    # stub its #suspend/#resume — the real ones drive the raw reader thread a
    # StringIO can't back. The drain (#take_pending_for_prompt) stays REAL; the
    # PTY lifecycle is covered by the *_pty specs. The stub records call order so
    # we can pin suspend→yield→resume. Stubbing a non-subject object is clean.
    let(:events) { [] }
    let(:live_composer) do
      described_class.new(input_queue: queue, input: StringIO.new, output: output).tap do |c|
        allow(c).to receive(:suspend) { events << :suspend }
        allow(c).to receive(:resume) { events << :resume }
      end
    end

    after { described_class.current = nil }

    it "yields nil with no active composer (prompt reads $stdin directly)" do
      described_class.current = nil
      expect { |b| described_class.run_in_terminal_with_pending(&b) }.to yield_with_args(nil)
    end

    it "suspends, drains the pending answer into the block, then resumes (in order)" do
      described_class.current = live_composer
      queue.push("sqlite")

      yielded = nil
      described_class.run_in_terminal_with_pending do |pending|
        yielded = pending
        events << :yield
      end

      expect(yielded).to eq("sqlite")                  # delivered into the block
      expect(events).to eq(%i[suspend yield resume])   # paused → prompt → resumed
      expect(queue.pending?).to be(false)              # not left to re-fire as a turn
    end

    it "does NOT consume the queue when consume_queue: false (approval menu)" do
      described_class.current = live_composer
      queue.push("yes")

      yielded = :unset
      described_class.run_in_terminal_with_pending(consume_queue: false) { |p| yielded = p }

      expect(yielded).to be_nil
      expect(queue.shift).to eq("yes")
    end

    it "resumes the composer even when the prompt block raises" do
      described_class.current = live_composer

      expect do
        described_class.run_in_terminal_with_pending { raise "picker hiccup" }
      end.to raise_error("picker hiccup")
      expect(events).to eq(%i[suspend resume]) # resume still runs in the ensure
    end
  end
end
