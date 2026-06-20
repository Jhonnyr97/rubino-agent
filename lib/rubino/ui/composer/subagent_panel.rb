# frozen_string_literal: true

module Rubino
  module UI
    module Composer
      # The SINGLE live representation of running background subagents, rendered
      # by the composer BELOW the input (next to the status footer). Replaces the
      # old split where the same subagent showed up twice — once as an inline card
      # block above the timeline and again as the navigable menu.
      #
      # Two faces, one place:
      #   - default: the compact, read-only cards (one calm line per subagent),
      #     supplied by the composer (UI::SubagentCards, fed from the registry);
      #   - when the user opens the picker (↓): the navigable UI::AgentMenu, so
      #     ↑/↓ select and Enter drills the chosen agent into the timeline.
      #
      # Pure composition: it owns no state and does no I/O — it just asks the
      # menu/cards for their rows. Empty array when nothing is live, so the
      # composer clears the region.
      class SubagentPanel
        # @param agent_menu [UI::AgentMenu] the navigable picker
        # @param cards [#call] returns the compact read-only card rows
        def initialize(agent_menu:, cards:)
          @agent_menu = agent_menu
          @cards = cards
        end

        # The rows to draw below the input this frame.
        def rows(cols)
          @agent_menu.open? ? @agent_menu.rows(cols) : Array(@cards.call)
        end
      end
    end
  end
end
