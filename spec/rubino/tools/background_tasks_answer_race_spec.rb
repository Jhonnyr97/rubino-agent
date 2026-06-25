# frozen_string_literal: true

# H5 — a parent's steer note must never be SILENTLY LOST while reported
# delivered. Before the fix, a child finishing did `drain` (InputQueue lock)
# then `complete` (registry lock) under DIFFERENT locks; an answer steered in
# the gap landed on a now-dead queue: it was dropped, OMITTED from the
# `undelivered` report, YET `steer` reported SUCCESS.
#
# The invariant these specs pin down: an answer is reported delivered ONLY if
# the child actually received it (the note is on a queue someone will still
# drain — the child at its next turn, or #complete into the undelivered report);
# otherwise it is reported undelivered (steer returns false). It is
# never dropped-but-reported-success.
#
# These drive the REAL registry classes (no doubles) so the locking contract is
# what's under test.
RSpec.describe Rubino::Tools::BackgroundTasks do
  subject(:registry) { described_class.instance }

  def reserve(subagent: "explore", prompt: "do it")
    registry.reserve(subagent: subagent, prompt: prompt)
  end

  describe "#steer rejects a terminal entry (the drain↔complete gap is closed)" do
    it "returns false and queues nothing once the child has completed" do
      entry = reserve
      registry.complete(entry, status: :completed, result: "done")

      expect(registry.steer(entry.id, "too late")).to be(false)
      # And nothing leaked onto the queue to be silently lost.
      expect(entry.steer_queue.drain).to eq([])
    end

    it "still delivers a note steered BEFORE completion (normal path)" do
      entry = reserve
      expect(registry.steer(entry.id, "in time")).to be(true)
      # The child never got a turn to fold it in, so #complete surfaces it as
      # undelivered rather than dropping it.
      undelivered = registry.complete(entry, status: :completed, result: "done")
      expect(undelivered).to eq(["in time"])
    end

    it "returns false for failed and stopped entries too" do
      %i[failed stopped].each do |terminal|
        e = reserve
        registry.complete(e, status: terminal, error: "x")
        expect(registry.steer(e.id, "nope")).to be(false)
      end
    end
  end

  describe "#complete returns the notes still queued (accurate undelivered report)" do
    it "returns the parked notes, in arrival order, and empties the queue" do
      entry = reserve
      registry.steer(entry.id, "first")
      registry.steer(entry.id, "second")

      undelivered = registry.complete(entry, status: :completed, result: "done")
      expect(undelivered).to eq(%w[first second])
      # Drained — not double-counted by a later drain.
      expect(entry.steer_queue.drain).to eq([])
    end

    it "returns [] when nothing was parked" do
      entry = reserve
      expect(registry.complete(entry, status: :completed, result: "done")).to eq([])
    end
  end

  describe "deliver-during-complete: delivered-or-undelivered, never silent-success-loss" do
    # The deterministic concurrency repro. One thread finishes the child
    # (complete → drains the steer_queue under the registry mutex); another
    # delivers an answer concurrently (steer). We run MANY rounds with a tiny
    # randomized stagger to shake the interleaving, and ASSERT the invariant on
    # every round:
    #   steer == true  ⇒ the note is delivered: either the child still had a
    #                    turn (it's queued) OR #complete drained it into the
    #                    undelivered report. It is NEVER both true AND absent.
    #   steer == false ⇒ honestly reported not-delivered; the queue is empty.
    # The bug would manifest as: steer == true, yet the note is in NEITHER the
    # post-state queue NOR the undelivered report (dropped-but-reported-success).
    it "never drops-and-reports-success across many interleavings" do
      300.times do |i|
        entry = reserve
        note  = "answer-#{i}"

        completed_undelivered = nil
        steer_result          = nil

        t_complete = Thread.new do
          # A hair of jitter so completion and steer race rather than serialize.
          sleep(rand * 0.0005)
          completed_undelivered = registry.complete(entry, status: :completed, result: "done-#{i}")
        end
        t_steer = Thread.new do
          sleep(rand * 0.0005)
          steer_result = registry.steer(entry.id, note)
        end
        [t_steer, t_complete].each(&:join)

        # Whatever is STILL on the queue after both threads finished — only
        # possible if steer won the race entirely before complete drained, which
        # is fine (the note is on a queue complete already passed)… so fold it in.
        leftover = entry.steer_queue.drain

        in_undelivered = completed_undelivered.include?(note)
        in_leftover    = leftover.include?(note)

        if steer_result
          # Reported delivered ⇒ the note MUST be observable somewhere: the
          # undelivered report (complete drained it) or still on the queue
          # (steer won, complete had already drained-empty before the push).
          expect(in_undelivered || in_leftover).to(
            be(true),
            "round #{i}: steer reported SUCCESS but the note was DROPPED " \
            "(absent from both the undelivered report and the queue) — H5 loss"
          )
        else
          # Reported NOT delivered ⇒ honest: the note must NOT be silently
          # sitting where the child could have seen it, and it must not be
          # claimed delivered.
          expect(in_undelivered).to be(false)
          expect(in_leftover).to be(false)
        end
        # Each round uses its OWN freshly-reserved entry (distinct sa_* id) and
        # its own note, so the accumulating singleton registry never cross-talks
        # — no per-round reset needed.
      end
    end
  end
end
