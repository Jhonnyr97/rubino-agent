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
        # between child events. Repaints go through the composer's render mutex, so
        # they never race the keystroke handler. Exits as soon as no child is live
        # (it clears the region one last time) or when killed on teardown.
        def start_ticker(composer)
          Thread.new do
            loop do
              sleep(IDLE_CARD_TICK)
              break unless composer.equal?(UI::BottomComposer.current)

              paint
              break unless children_live?
            end
          rescue StandardError
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
