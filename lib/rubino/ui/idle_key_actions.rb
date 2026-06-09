# frozen_string_literal: true

module Rubino
  module UI
    # Module-level registry bridging the idle Reline prompt's custom editor
    # actions back to the CLI.
    #
    # WHY a registry: the Shift+Tab / Ctrl+O editor actions live in a module
    # prepended into `Reline::LineEditor` (see RelineDropdownNav), so at call
    # time `self` is the LineEditor instance — it has no reference to the
    # ChatCommand or its #cycle_mode / reveal-reasoning handlers. The CLI sets
    # the procs here once before entering the readline loop; the editor actions
    # invoke whatever is registered, or no-op when nothing is.
    #
    # The BottomComposer (the in-turn input path) already routes the SAME two
    # keys through `on_mode_cycle`/`on_ctrl_o` callbacks; the CLI registers the
    # very same handlers here so both input paths share one implementation.
    module IdleKeyActions
      class << self
        # Proc called when Shift+Tab is pressed at the idle prompt. Expected to
        # cycle the agent mode (and may return the freshly-built prompt chip).
        attr_accessor :on_mode_cycle

        # Proc called when Ctrl+O is pressed at the idle prompt. Expected to
        # reveal the last retained reasoning aside.
        attr_accessor :on_reveal_reasoning

        # GATE (item 5 / interim cover for D1/D3/D4): true while a turn is
        # running/streaming. The idle key actions (Ctrl+O reveal, Shift+Tab mode
        # cycle) must only act when the IDLE prompt is the active reader — during
        # a turn their out-of-band $stdout writes race the streaming writer and
        # smear into / inject reasoning text between the answer chunks. The chat
        # loop sets this around #run_turn (begin/end_turn!) so both the Reline
        # idle actions AND the in-turn BottomComposer callbacks — which route
        # through the SAME cycle_mode/reveal_reasoning here — become a hard no-op
        # while a turn is active. (Full clean live-during-stream behaviour is the
        # pinned-composer job; here we only stop the corruption.)
        attr_accessor :turn_active

        # Mark a turn as running — idle key actions no-op until end_turn!.
        def begin_turn!
          @turn_active = true
        end

        # Mark the turn finished — idle key actions act again.
        def end_turn!
          @turn_active = false
        end

        # Invoke the mode-cycle callback if registered. Returns its value (the
        # new prompt chip, when the handler supplies one) or nil. No-op while a
        # turn is active (the gate). Fully guarded: a raising handler must never
        # take down the prompt.
        def cycle_mode
          return nil if @turn_active

          on_mode_cycle&.call
        rescue StandardError
          nil
        end

        # Invoke the reveal-reasoning callback if registered. No-op while a turn
        # is active (the gate). Guarded.
        def reveal_reasoning
          return nil if @turn_active

          on_reveal_reasoning&.call
        rescue StandardError
          nil
        end

        # Drop both callbacks and clear the gate (used by specs for a clean
        # slate).
        def reset!
          @on_mode_cycle = nil
          @on_reveal_reasoning = nil
          @turn_active = false
        end
      end
    end
  end
end
