# frozen_string_literal: true

require "reline"
require_relative "idle_key_actions"

module Rubino
  module UI
    # Deliberate, contained `prepend` into Reline::LineEditor.
    #
    # WHY a prepend: in Reline 0.6.3 the autocompletion dropdown can ONLY be
    # navigated with Tab (the native `complete` action runs
    # `move_completed_list(:down)` and wraps). The arrow keys are hard-bound to
    # history (`ed_prev_history` / `ed_next_history`). The journey actions
    # (`completion_journey_up` / `completion_journey_down`) exist but no keymap
    # binds them, and `input_key` tears the journey state down on the next key
    # unless `@completion_occurs` is set. There is no public hook that lets a
    # single key "navigate the dialog if it's open, else move through history",
    # so we add two new actions on the editor and bind the arrows to them via
    # the supported public `Reline.core.config.bind_key` API (see LineInput).
    #
    # This mirrors rubish's proven mechanism. The module is intentionally tiny
    # and defensive: every Reline internal it touches is guarded so a future
    # Reline that renames an ivar/method degrades to plain history navigation
    # instead of crashing the prompt.
    module RelineDropdownNav
      # True only while the autocomplete dialog is actually on screen.
      #
      # `@completion_journey_state` alone is set on essentially any edit, so it
      # cannot tell us the dialog is *visible*. The `@dialogs` check — an
      # :autocomplete dialog whose `contents` is populated — is what confirms
      # the menu is rendered and therefore navigable.
      def dropdown_open?
        return false unless @config&.autocompletion
        return false unless @completion_journey_state
        return false unless @dialogs.respond_to?(:any?)

        @dialogs.any? do |d|
          d.respond_to?(:name) && d.name == :autocomplete &&
            d.respond_to?(:contents) && d.contents
        end
      end

      # Up: navigate the dialog when open, else previous history entry.
      def completion_or_up(key)
        if dropdown_open? && respond_to?(:completion_journey_move, true)
          # Clamp at the top instead of letting Reline's modulo wrap drop the
          # pointer onto the raw typed target (journey index 0), which renders
          # as "no selection" and visually collapses the menu. The first real
          # candidate is journey index 1; refuse to move below it (F7 — mirrors
          # the approval menu, which clamps both ends).
          completion_journey_move(:up) unless at_first_candidate?
          # Keep input_key from resetting @completion_journey_state on the next
          # keypress — without this the journey collapses after one move.
          @completion_occurs = true
        else
          ed_prev_history(key)
        end
      end

      # Down: navigate the dialog when open, else next history entry.
      def completion_or_down(key)
        if dropdown_open? && respond_to?(:completion_journey_move, true)
          # Clamp at the bottom: arrowing past the last item would wrap to the
          # raw target and collapse the dropdown (F7). Stay on the last
          # candidate instead.
          completion_journey_move(:down) unless at_last_candidate?
          @completion_occurs = true
        else
          ed_next_history(key)
        end
      end

      # Journey pointer 0 is the raw typed target; real candidates start at 1.
      def at_first_candidate?
        st = @completion_journey_state
        st.respond_to?(:pointer) && st.pointer <= 1
      rescue StandardError
        false
      end

      def at_last_candidate?
        st = @completion_journey_state
        st.respond_to?(:pointer) && st.respond_to?(:list) &&
          st.pointer >= st.list.size - 1
      rescue StandardError
        false
      end

      # Escape: cancel a half-typed slash command. Dismisses the autocomplete
      # dialog WITHOUT committing the currently arrowed candidate AND clears the
      # in-progress `/token` from the composer (F8 — previously ESC only closed
      # the menu and left `/xyz` in the buffer; L8 — and it used to leak the
      # highlighted entry, e.g. "/exit", into the buffer).
      #
      # D6: ESC must clear the in-progress `/token` even when the dropdown has
      # ALREADY been torn down by an intervening edit. Arrowing the journey
      # commits the highlighted candidate into the line buffer (Reline's
      # move_completed_list calls set_current_line); a subsequent Backspace then
      # resets @completion_journey_state to nil (input_key, !@completion_occurs),
      # so the dialog is no longer "open" — but the partial candidate (e.g.
      # `/repl`) is still sitting in the buffer. If ESC only acted while the
      # dropdown was open it would leave that fragment, which then fuses with the
      # retyped command into garbage like `/repreaso`. So we clear an in-progress
      # `/…` token unconditionally. clear_inprogress_slash_command only touches a
      # lone single-line `/…` buffer, so a lone ESC on plain text (or multi-line
      # work) stays a harmless no-op. Every internal touched is guarded so a
      # Reline rename degrades to "do nothing" rather than crashing the prompt.
      def dismiss_completion_dialog(key)
        if dropdown_open?
          tear_down_completion_dialog
          clear_inprogress_slash_command
          return nil
        end

        # Dropdown already closed: still scrub any leftover `/…` fragment so a
        # retype builds a clean token; otherwise behave like the native no-op.
        return nil if clear_inprogress_slash_command

        ed_unassigned(key)
      rescue StandardError
        nil
      end

      # Tear down the journey so the highlighted candidate is NOT committed, and
      # force the dialogs to re-render closed on the next paint.
      def tear_down_completion_dialog
        @completion_journey_state = nil
        @completion_occurs = false
        return unless @dialogs.respond_to?(:each)

        @dialogs.each do |d|
          d.contents = nil if d.respond_to?(:name) && d.name == :autocomplete && d.respond_to?(:contents=)
        end
      end

      # Clears a half-typed slash command (a single-line buffer beginning with
      # "/") so ESC cancels the whole token, not just the dropdown. Only acts on
      # a lone "/…" line — multi-line input or non-slash text is left untouched
      # so ESC never destroys real work. Uses the public set_current_line seam
      # (same one Reline's own completion uses) and is fully guarded.
      #
      # Returns true when it cleared a `/…` token, false/nil otherwise, so the
      # caller can decide whether ESC also needs the native no-op (D6).
      def clear_inprogress_slash_command
        return false unless respond_to?(:current_line, true) && respond_to?(:set_current_line, true)

        line = current_line.to_s
        return false unless line.start_with?("/")
        # Only a single-line buffer — never flatten/destroy a multi-line draft.
        lines = instance_variable_get(:@buffer_of_lines)
        return false if lines.respond_to?(:size) && lines.size > 1

        set_current_line("", 0)
        true
      rescue StandardError
        false
      end

      # Shift+Tab at the idle prompt: cycle the agent mode. The editor action
      # runs in the LineEditor instance context (no view of the CLI), so it
      # delegates to the app callback registered in IdleKeyActions — the SAME
      # handler the in-turn BottomComposer uses, so both input paths share one
      # "cycle mode" implementation. The handler persists the new mode and
      # prints the transient `┄ mode · … ┄` footer itself (so the change is
      # confirmed on screen); the visible prompt chip then reflects the new mode
      # on the NEXT prompt. We do NOT poke Reline's @prompt/rerender internals
      # mid-line — that path is fragile in 0.6.3 and the footer already confirms
      # the switch. Fully guarded so a raising handler never crashes the prompt.
      def rubino_cycle_mode(_key)
        IdleKeyActions.cycle_mode if defined?(IdleKeyActions)
        nil
      rescue StandardError
        nil
      end

      # Ctrl+O at the idle prompt: reveal the last retained reasoning aside.
      # Same registry bridge + guarded style as rubino_cycle_mode.
      def rubino_reveal_reasoning(_key)
        IdleKeyActions.reveal_reasoning if defined?(IdleKeyActions)
        nil
      rescue StandardError
        nil
      end

      # Aliases in case a terminal/inputrc prefers the history-named actions.
      alias_method :completion_or_prev_history, :completion_or_up
      alias_method :completion_or_next_history, :completion_or_down
    end
  end
end

if defined?(Reline::LineEditor)
  Reline::LineEditor.prepend(Rubino::UI::RelineDropdownNav)
end
