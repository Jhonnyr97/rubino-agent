# frozen_string_literal: true

module Rubino
  module Tools
    # steer — the MODEL-callable parent->child steering note (S2). The model
    # counterpart of the human `/agents <id> steer "..."` affordance: a parent
    # agent parks a note onto one of ITS OWN running children; the note is folded
    # into that child's context at its next turn boundary (Loop#inject_steered_input
    # via the child's steer_queue) and PERSISTS — it changes the child's
    # trajectory, unlike the ephemeral `probe`.
    #
    # SCOPED AT CALL (the S1 correction): steer is registered for ALL agents and
    # authorized by OWNERSHIP at call time. The caller is the thread-local
    # Rubino.current_subagent_id (nil ⇒ the human / top-level agent). The target
    # must be the caller's OWN DIRECT child (BackgroundTasks.owned_by?), so a node
    # with no children simply gets a "not your child" error. This tool does NOT
    # touch the human CLI path (executor.rb's steer_agent stays unscoped) and is
    # NOT on any strip list.
    #
    # Mechanism reuse: it wraps Tools::BackgroundTasks#steer verbatim (the SAME wire the
    # human CLI uses) — no new transport, no new state.
    class SteerTool < Rubino::Tool
      redaction :none

      # Gated by the same `tools.task` delegation key — steering a child is
      # meaningless without the delegation substrate. Disabling delegation
      # disables steer too.
      def config_key
        "task"
      end

      describe "Steer one of YOUR OWN running subagents: park a short note that is " \
                  "folded into that child's context at its NEXT turn (it persists and " \
                  "changes what the child does). Use it to course-correct a child you " \
                  "started — add a constraint, narrow the scope, flag something it missed. " \
                  "You can ONLY steer subagents you started (your direct children); you " \
                  "cannot steer yourself, a sibling, or a finished child. The note is " \
                  "queued, not delivered instantly — the child sees it between turns."

      string :task_id, "The id (sa_…) of YOUR running subagent to steer."
      string :note, "The steering note to fold into the child's next turn. Keep it short and self-contained."

      def execute(task_id:, note:)
        task_id = task_id.to_s.strip
        note    = note.to_s.strip

        caller_id = Rubino.current_subagent_id
        registry  = Tools::BackgroundTasks.instance
        entry     = task_id.empty? ? nil : registry.find(task_id)

        # No such id at all → it is not a steerable running subagent.
        return "Cannot steer #{task_id} — no such running subagent." unless entry
        # Self-steer is meaningless and would loop a note into your own context.
        return "Error: cannot steer yourself." if task_id == caller_id
        # Ownership: only a DIRECT child of the caller may be steered.
        unless registry.owned_by?(caller_id, task_id)
          return "Error: #{task_id} is not one of your subagents — you can only steer children you started."
        end
        # A finished child has no live loop to fold the note into.
        return "Cannot steer #{task_id} — it already finished (#{entry.status})." unless live?(entry.status)

        # Wraps the SAME wire the human CLI uses. A false here means the child's
        # queue vanished between checks (a just-finished child) — treat as gone.
        return "Cannot steer #{task_id} — no such running subagent." unless registry.steer(task_id, note)

        "steer ▸ #{task_id} ← #{Rubino::Util::Output.elide(note, 80)}  (parked · enters child context next turn)"
      end

      private

      # A child still holds a loop (its thread is alive) while running or
      # awaiting approval, so a steer note can still reach it.
      def live?(status)
        %i[running needs_approval].include?(status)
      end
    end
  end
end
