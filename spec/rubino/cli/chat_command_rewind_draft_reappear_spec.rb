# frozen_string_literal: true

require "stringio"
require "timeout"

# Regression for the Esc-Esc rewind "picked message reappears in the input and
# survives deletes" bug.
#
# The rewind pre-fills the composer with the picked message as a ONE-SHOT edit
# affordance (#prefill). The bug: read_idle_line's ensure (and stop_composer)
# snapshotted ANY non-empty buffer into @pending_draft, so an unedited prefill
# left in the buffer — e.g. because the idle poll loop broke on a queued/routed
# line instead of a submit — was carried and RE-SEEDED on every later prompt,
# reappearing turn after turn even after the user deleted it.
#
# The fix: an untouched prefill (#pristine_prefill?) is never captured as a
# draft. These specs drive the REAL BottomComposer through the REAL
# read_idle_line so the prefill/take/reset/pristine_prefill? seam is exercised
# end-to-end; only handle_rewind's heavy fork machinery is stubbed down to its
# composer-visible effect (prefill + a fork runner).
RSpec.describe Rubino::CLI::ChatCommand do
  let(:command) { described_class.new({}) }
  let(:queue)   { Rubino::Interaction::InputQueue.new }
  let(:runner)  { instance_double(Rubino::Agent::Runner) }
  let(:composer) do
    Rubino::UI::BottomComposer.new(input_queue: queue, input: fake_term_io, output: fake_term_io)
  end

  # A StringIO that answers #winsize so the composer's wrap math is deterministic
  # without a real terminal, and reports NOT a tty so #start's raw path stays
  # inert (we drive the composer directly, no live reader thread).
  def fake_term_io
    io = StringIO.new
    def io.winsize = [24, 80]
    def io.tty? = false
    io
  end

  before do
    command.instance_variable_set(:@composer, composer)
    allow(command).to receive_messages(
      idle_cards: instance_double(Rubino::CLI::Chat::IdleCardHost, paint: nil, children_live?: false),
      update_polishing_indicator: false,
      auto_resolve_pending_subagent_request: false,
      build_prompt: "> ",
      build_status_line: "",
      attached_to_agent?: false,
      # Keep the per-phase hooks inert so they never call unstubbed runner methods.
      ctrl_o_handler: nil, mode_cycle_handler: nil, agent_cycle_handler: nil,
      idle_polishing_escape: nil
    )
    # handle_rewind: reproduce ONLY its composer-visible effect + fork adoption.
    allow(command).to receive(:handle_rewind) do |comp, _runner, _ui|
      comp.prefill("original message")
      instance_double(Rubino::Agent::Runner) # the fork runner the REPL adopts
    end
    allow(Rubino).to receive(:ui).and_return(Rubino::UI::Null.new)
  end

  def pending_draft = command.instance_variable_get(:@pending_draft)

  # Fire the composer's Esc-Esc chord (two lone Escs within the window) once the
  # idle poll loop has wired on_double_esc via #reconfigure.
  def arm_rewind
    composer.send(:handle_lone_esc)
    composer.send(:handle_lone_esc)
  end

  # Run read_idle_line to completion, driving the composer from a helper thread.
  def read_idle(&drive)
    reader = Thread.new(&drive)
    line = Timeout.timeout(3) { command.send(:read_idle_line, queue, nil, runner) }
    reader.join
    line
  end

  describe "a queued/routed line breaks the loop while the prefill is un-submitted" do
    it "does NOT carry the untouched prefill into @pending_draft" do
      line = read_idle do
        sleep 0.15               # let the poll loop wire on_double_esc
        arm_rewind               # -> handle_rewind -> prefill("original message")
        Timeout.timeout(2) { sleep 0.01 until composer.buffer == "original message" }
        # A line arrives from a source OTHER than submitting THIS buffer (a routed
        # control line / type-ahead), so #shift breaks the loop with the prefill
        # still in the buffer — no take_buffer ran.
        queue.push("some other line")
      end

      expect(line).to eq("some other line")
      # The prefill is a one-shot affordance, not a sticky draft.
      expect(pending_draft).to be_nil
    end
  end

  describe "the normal edit-and-resend path" do
    it "runs the edited turn and leaves nothing to reappear" do
      line = read_idle do
        sleep 0.15
        arm_rewind
        Timeout.timeout(2) { sleep 0.01 until composer.buffer == "original message" }
        composer.handle_key("!")             # edit the prefilled text in place
        composer.handle_key("\r")            # submit: take_buffer clears + pushes
      end

      expect(line).to eq("original message!")
      expect(composer.buffer).to eq("")
      expect(pending_draft).to be_nil

      # The turn-end capture must also leave nothing behind.
      command.send(:stop_composer, composer)
      expect(pending_draft).to be_nil
    end
  end

  describe "a genuinely EDITED (diverged) prefill left un-submitted" do
    it "is still carried as a draft (only an UNTOUCHED prefill is dropped)" do
      read_idle do
        sleep 0.15
        arm_rewind
        Timeout.timeout(2) { sleep 0.01 until composer.buffer == "original message" }
        composer.handle_key("!")             # a real edit diverges the buffer
        queue.push("routed line")            # break the loop without submitting
      end

      # The user changed it into their own draft, so it IS preserved (same as any
      # half-typed line) — this is the intended carry-over, not the bug.
      expect(pending_draft).to eq("original message!")
    end
  end
end
