# frozen_string_literal: true

require "timeout"

# #561: when the main agent delegates to TWO+ BACKGROUND subagents and its turn
# ENDS before the slower child finishes, the children's `[background-task]`
# completion notices land on the parent's InputQueue (#push_notice) with nothing
# to carry them — the mid-turn fold-in (Loop#inject_steered_input) only fires
# while the parent is still iterating. The parent used to sit at the idle prompt
# forever, never delivering the combined result.
#
# The fix: #read_idle_line's poll loop now AUTONOMOUSLY starts ONE coalesced
# follow-up turn when notices are parked, the input buffer is idle, and no typed
# line is waiting. It drains ALL parked notices into a single resume prompt
# (#coalesced_resume_prompt) and returns it, so the REPL re-enters #run_turn and
# the parent processes/summarises the children's results. Guards: a typed line
# always wins (#notices_pending? is false the moment a line exists); a non-empty
# buffer defers (the user is mid-line); the drain is one-shot (no re-trigger).
RSpec.describe Rubino::CLI::ChatCommand do
  # A plain collaborator instance (NOT the declared subject) so stubbing its
  # private idle-loop side-helpers stays legitimate — mirrors the Ctrl+D spec.
  let(:command)  { described_class.new({}) }
  let(:queue)    { Rubino::Interaction::InputQueue.new }
  let(:composer) { build_composer }

  # Fake composer with an EMPTY idle buffer (the user is not mid-typing) so the
  # autonomous resume is allowed to fire. Only the surface the poll loop touches.
  def build_composer(buffer: "")
    instance_double(
      Rubino::UI::BottomComposer,
      start: nil,
      buffer: buffer,
      stop: nil,
      reconfigure: nil,
      reset_input: nil,
      quit_pending?: false,
      clear_quit_pending: nil
    )
  end

  before do
    # BUG 02: ONE composer per session; #read_idle_line RECONFIGURES the shared
    # @composer instead of constructing a fresh one. Inject the fake as @composer.
    command.instance_variable_set(:@composer, composer)
    allow(command).to receive_messages(
      seed_draft: nil,
      idle_cards: instance_double(Rubino::CLI::Chat::IdleCardHost, paint: nil, children_live?: false),
      update_polishing_indicator: false,
      auto_resolve_pending_subagent_request: false,
      build_prompt: "> ",
      build_status_line: "",
      composer_rail: nil
    )
  end

  describe "#read_idle_line autonomous background-subagent resume (#561)" do
    it "starts ONE follow-up turn that drains a parked notice" do
      queue.push_notice("[background-task] sa_1 completed.\nResult:\nfound the bug")

      line = Timeout.timeout(3) { command.send(:read_idle_line, queue, nil, nil) }

      expect(line).to include("[background-task] sa_1 completed")
      expect(line).to include("found the bug")
      # Drained exactly once — nothing left to re-trigger a second turn.
      expect(queue.notices_pending?).to be(false)
      expect(queue.pending?).to be(false)
    end

    it "COALESCES two completions into a SINGLE resume turn (not one per child)" do
      queue.push_notice("[background-task] sa_1 completed.\nResult:\nchild one done")
      queue.push_notice("[background-task] sa_2 completed.\nResult:\nchild two done")

      line = Timeout.timeout(3) { command.send(:read_idle_line, queue, nil, nil) }

      # Both children's results ride the ONE prompt returned, and the queue is
      # fully drained — a later idle pass finds nothing, so no duplicate turn.
      expect(line).to include("child one done")
      expect(line).to include("child two done")
      expect(queue.notices_pending?).to be(false)
    end

    it "frames the resume as an instruction to deliver the combined summary" do
      queue.push_notice("[background-task] sa_1 completed.\nResult:\ndone")

      line = Timeout.timeout(3) { command.send(:read_idle_line, queue, nil, nil) }

      expect(line).to include("background subagents finished")
      expect(line).to match(/summary|combined answer/i)
    end

    it "is NOT echoed as a typed user message (no @input_from_queue marker)" do
      queue.push_notice("[background-task] sa_1 completed.\nResult:\ndone")

      Timeout.timeout(3) { command.send(:read_idle_line, queue, nil, nil) }

      expect(command.instance_variable_get(:@input_from_queue)).to be_nil
    end

    it "DEFERS while the user is mid-line (non-empty buffer never pre-empted)" do
      typing = build_composer(buffer: "half-typed prompt")
      command.instance_variable_set(:@composer, typing)
      queue.push_notice("[background-task] sa_1 completed.\nResult:\ndone")

      # The notice must NOT pre-empt the draft: the buffer guard defers, so the
      # poll loop never returns the synthetic prompt. The user then submits a
      # line, which we simulate by pushing one after a beat — it wins.
      pusher = Thread.new do
        sleep 0.15
        queue.push("the user's own line")
      end

      line = Timeout.timeout(3) { command.send(:read_idle_line, queue, nil, nil) }
      pusher.join

      # The typed line was returned, NOT the synthetic resume; the notice stayed
      # parked (it folds in on that turn through the normal #13 path), undiscarded.
      expect(line).to eq("the user's own line")
      expect(line).not_to include("[background-task]")
      expect(queue.notices_pending?).to be(true)
    end

    it "DEFERS while ATTACHED to a subagent — a resume here would be steered into the child (#51)" do
      # The view is scoped to a subagent (the user drilled in / detached to it).
      # A line returned from the idle read is intercepted by the REPL's
      # attached-input handler and STEERED into the focused child, so firing the
      # synthetic resume here would feed the parent's `[background subagents
      # finished …]` prompt to the child and DRAIN the notices — the parent then
      # never delivers the combined result. The resume must NOT fire while
      # attached: the read BLOCKS (the notice stays parked) until the user returns
      # to the main prompt.
      command.instance_variable_set(:@attached_id, "sa_1")
      queue.push_notice("[background-task] sa_1 completed.\nResult:\ndone")

      # Pre-fix the unguarded resume fires immediately and returns the synthetic
      # line; the read does NOT block, so this timeout never trips. The guard
      # makes the read block while attached → the timeout fires, proving deferral.
      expect { Timeout.timeout(0.4) { command.send(:read_idle_line, queue, nil, nil) } }
        .to raise_error(Timeout::Error)
      # The notice was NOT drained into a steer — it survives for the parent turn.
      expect(queue.notices_pending?).to be(true)

      # Returning to the main view (← / /back clears @attached_id) frees the
      # resume: now the same parked notice drives the ONE parent follow-up turn.
      command.instance_variable_set(:@attached_id, nil)
      line = Timeout.timeout(3) { command.send(:read_idle_line, queue, nil, nil) }
      expect(line).to include("[background-task] sa_1 completed")
      expect(line).to include("background subagents finished")
      expect(queue.notices_pending?).to be(false)
    end

    it "a typed line waiting ALONGSIDE notices wins (the line consumes first)" do
      queue.push_notice("[background-task] sa_1 completed.\nResult:\ndone")
      queue.push("typed first")

      line = Timeout.timeout(3) { command.send(:read_idle_line, queue, nil, nil) }

      expect(line).to eq("typed first")
      # The notice survives for the turn the typed line starts (#13 fold-in).
      expect(queue.notices_pending?).to be(true)
    end
  end

  describe "#coalesced_resume_prompt" do
    it "joins all notices into one act-on-it framed prompt" do
      prompt = command.send(:coalesced_resume_prompt,
                            ["[background-task] sa_1 done", "[background-task] sa_2 done"])
      expect(prompt).to include("sa_1 done")
      expect(prompt).to include("sa_2 done")
      expect(prompt).to match(/deliver the combined/i)
      expect(prompt).to match(/do not re-delegate/i)
    end
  end

  describe "#idle_buffer_empty?" do
    it "is true for a nil composer (no buffer to protect)" do
      expect(command.send(:idle_buffer_empty?, nil)).to be(true)
    end

    it "is true for an empty / whitespace-only buffer" do
      expect(command.send(:idle_buffer_empty?, build_composer(buffer: "   "))).to be(true)
    end

    it "is false when the user has typed something" do
      expect(command.send(:idle_buffer_empty?, build_composer(buffer: "hi"))).to be(false)
    end
  end
end
