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

        # Invoke the mode-cycle callback if registered. Returns its value (the
        # new prompt chip, when the handler supplies one) or nil. Fully guarded:
        # a raising handler must never take down the prompt.
        def cycle_mode
          on_mode_cycle&.call
        rescue StandardError
          nil
        end

        # Invoke the reveal-reasoning callback if registered. Guarded.
        def reveal_reasoning
          on_reveal_reasoning&.call
        rescue StandardError
          nil
        end

        # Drop both callbacks (used by specs to restore a clean slate).
        def reset!
          @on_mode_cycle = nil
          @on_reveal_reasoning = nil
        end
      end
    end
  end
end
