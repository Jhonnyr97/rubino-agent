# frozen_string_literal: true

module Rubino
  module CLI
    module Chat
      # Hosts the collapsed background-subagent card region (F1) at the IDLE
      # prompt, extracted from ChatCommand (#17): repaints the registry's live
      # snapshot onto whatever BottomComposer currently owns the screen, and
      # owns the low-frequency ticker thread that keeps the cards fresh in the
      # quiet gaps between child events.
      class IdleCardHost
        # How often (seconds) the idle card region repaints on its own so the
        # cards' elapsed-time field advances even when no child event fires, and so
        # we promptly notice the last child finishing. Child tool start/finish
        # already poke an immediate repaint via #set_subagent_cards; this tick only
        # covers the quiet gaps.
        IDLE_CARD_TICK = 1.0

        # When the agent-menu picker is OPEN the idle ticker runs at the same
        # 0.1 s cadence as the status-bar thread so the dropdown reflects live
        # registry changes at idle too (#DROPDOWN_LIVE).
        MENU_REFRESH_TICK = 0.1

        # True when at least one background subagent (the `task` tool's default)
        # is still live — running or parked on a human approval. Drives whether the
        # idle prompt hosts the collapsed live cards (F1).
        def children_live?
          Tools::BackgroundTasks.instance.running.any?
        rescue StandardError
          false
        end

        # Repaints the idle card region from the registry's current snapshot. Mirrors
        # UI::CLI#set_subagent_cards (which the child taps call), but is callable
        # from the REPL's own ticker without a parent UI handle — both ultimately
        # drive BottomComposer#set_cards under the render mutex.
        def paint
          composer = UI::BottomComposer.current
          return unless composer

          entries = Tools::BackgroundTasks.instance.running
          composer.set_cards(cards.card_lines(entries))
        rescue StandardError
          nil # a card repaint is cosmetic — never break the idle prompt.
        end

        # A low-frequency ticker that repaints the idle card region so the elapsed
        # time advances and a finished last-child is noticed even in a quiet gap
        # between child events. When the agent-menu picker is OPEN the cadence
        # bumps to MENU_REFRESH_TICK (0.1 s) so the dropdown reflects live registry
        # changes at idle too (#DROPDOWN_LIVE) — the same parity as the mid-turn
        # status thread. Repaints go through the composer's render mutex, so they
        # never race the keystroke handler. Exits when no child is live AND the
        # picker is closed (or when killed on teardown). While the picker is open
        # the ticker stays alive so the open menu keeps repainting until it closes
        # itself (via refresh! when items go empty).
        # +on_tick+ (optional) runs once per tick after the card repaint — used by
        # the attach view to live-tail a focused shell's new output on the SAME
        # cadence and through the same render mutex (composer#print_above) the
        # cards use, so it never races the keystroke handler.
        def start_ticker(composer, &on_tick)
          Thread.new do
            loop do
              tick = composer.agent_menu_open? ? MENU_REFRESH_TICK : IDLE_CARD_TICK
              sleep(tick)
              break unless composer.equal?(UI::BottomComposer.current)

              paint
              on_tick&.call
              break unless children_live? || composer.agent_menu_open?
            end
          rescue StandardError => e
            # The ticker exits on any error so a hiccup never crashes the REPL,
            # but a swallowed coding bug would silently kill the live-card refresh
            # for the rest of the session with no trace. Log it once (this rescue
            # only ever fires once per ticker — the loop is already dead here).
            Rubino.logger.warn(event: "cli.idle_card_ticker.crashed",
                               error: e.message, error_class: e.class.name)
            nil
          end
        end

        private

        def cards
          @cards ||= UI::SubagentCards.new
        end
      end
    end
  end
end
