# frozen_string_literal: true

require "pastel"

module Rubino
  module UI
    # Live subagent picker hosted by the bottom composer. It only chooses an
    # entry; the /agents command remains the single owner of drill-in semantics.
    class AgentMenu
      MAX_ROWS = 5

      # The synthetic "return to the main session" row, shown at the BOTTOM of the
      # picker so the list is a switcher: pick a subagent to attach/switch to it,
      # or pick "main" to leave an attached agent (a no-op at the main prompt). A
      # tiny struct so it answers #id like a real row (the refresh re-selection
      # finds it by id). Identity-compared via .main_row?.
      MAIN_ROW = Struct.new(:id).new("__main__").freeze

      def self.main_row?(entry) = entry.equal?(MAIN_ROW)

      def initialize(entries: -> { Tools::BackgroundTasks.instance.running }, pastel: Pastel.new)
        @entries = entries
        @pastel = pastel
        @state = nil
      end

      def open?
        !@state.nil?
      end

      def open!
        items = menu_items
        return if items.empty?

        @state = { items: items, selected: 0, top: 0 }
      end

      # The picker rows: the live subagents, then the "◂ main" row at the bottom.
      # Empty (so the picker stays closed) when no subagent is live — there is
      # nothing to switch between and "main" alone would be a pointless prompt.
      def menu_items
        live = live_entries
        return [] if live.empty?

        live + [MAIN_ROW]
      end

      def close!
        @state = nil
      end

      # Move the highlight up one. ↑ off the TOP of the list EXITS the picker:
      # the menu closes itself (it owns its own lifecycle) so focus returns to the
      # input — no stranded ❯ marker. Returns true while it stayed open and moved,
      # false when it closed (or was already closed), so the caller can just
      # `up!; redraw` without re-implementing the focus hand-off.
      def up! # rubocop:disable Naming/PredicateMethod -- a bang mutator that also reports whether it stayed open, not a pure query
        return false unless open?

        if @state[:selected].zero?
          close!
          return false
        end

        @state[:selected] -= 1
        sync_top
        true
      end

      def down
        return open! unless open?

        @state[:selected] = [@state[:selected] + 1, @state[:items].size - 1].min
        sync_top
        true
      end

      def selected
        return unless open?

        @state[:items][@state[:selected]]
      end

      def accept
        entry = selected
        close!
        entry
      end

      def refresh!
        return unless open?

        previous = selected&.id
        items = menu_items
        if items.empty?
          close!
          return
        end

        selected = items.index { |entry| entry.id == previous } || 0
        @state = { items: items, selected: selected, top: window_top(selected, items.size) }
      end

      # The rendered picker rows, or [] when closed. Delegates the look — the
      # `┄ subagents ┄` header, the scroll-window slice, the cyan ❯ + inverse
      # highlight, the dim ┊ rest, the selected row's live-activity sub-line, and
      # the overflow footer — to the shared {MenuView}, so this picker and the
      # `/` command palette render alike (#562). This menu still owns its rows:
      # the status-coloured `id · subagent · status` label, the `◂ main` row, and
      # which entry carries an activity sub-line.
      def rows(cols)
        return [] unless open?

        refresh!
        return [] unless open?

        descriptors = @state[:items].map { |entry| descriptor(entry) }
        MenuView.render(descriptors, cols,
                        window: { selected: @state[:selected], top: @state[:top], max_rows: MAX_ROWS },
                        header: "subagents", hints: "Enter attaches · ← back")
      end

      private

      # A {MenuView} row descriptor for one picker entry: the label is the
      # status-coloured `id · subagent · status` (or the dim `◂ main session`
      # row), and a live subagent's last-activity rides along as the sub-line
      # MenuView draws under it when selected.
      def descriptor(entry)
        if self.class.main_row?(entry)
          { label: @pastel.dim("◂ main session") }
        else
          { label: "#{entry.id} · #{entry.subagent} · #{status_label(entry)}",
            sub: entry.last_activity.to_s }
        end
      end

      def live_entries
        Array(@entries.call).select { |entry| live?(entry) }
      rescue StandardError
        []
      end

      def live?(entry)
        %i[running needs_approval blocked_on_human blocked_on_parent stopping].include?(entry.status)
      end

      # A budget request (#574) reuses :needs_approval but reads as "wants
      # +budget" so the human knows the Enter grants iterations, not a tool.
      def status_label(entry)
        case entry.status
        when :needs_approval then @pastel.yellow(entry.budget_request ? "wants +budget" : "approval")
        when :blocked_on_human then @pastel.red("waiting on you")
        when :blocked_on_parent then @pastel.red("waiting on parent")
        when :stopping then "stopping"
        else "running"
        end
      end

      def sync_top
        @state[:top] = window_top(@state[:selected], @state[:items].size)
      end

      def window_top(selected, size)
        MenuView.window_top(selected, size, @state[:top], MAX_ROWS)
      end
    end
  end
end
