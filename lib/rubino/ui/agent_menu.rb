# frozen_string_literal: true

require "pastel"

module Rubino
  module UI
    # Live subagent picker hosted by the bottom composer. It only chooses an
    # entry; the /agents command remains the single owner of drill-in semantics.
    class AgentMenu
      MAX_ROWS = 5

      def initialize(entries: -> { Tools::BackgroundTasks.instance.running }, pastel: Pastel.new)
        @entries = entries
        @pastel = pastel
        @state = nil
      end

      def open?
        !@state.nil?
      end

      def open!
        items = live_entries
        return if items.empty?

        @state = { items: items, selected: 0, top: 0 }
      end

      def close!
        @state = nil
      end

      def up!
        return unless open?

        @state[:selected] = [@state[:selected] - 1, 0].max
        sync_top
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
        items = live_entries
        if items.empty?
          close!
          return
        end

        selected = items.index { |entry| entry.id == previous } || 0
        @state = { items: items, selected: selected, top: window_top(selected, items.size) }
      end

      def rows(cols)
        return [] unless open?

        refresh!
        return [] unless open?

        items = @state[:items]
        top = @state[:top]
        selected = @state[:selected]
        slice = items[top, MAX_ROWS] || []
        rows = [@pastel.dim("┄ subagents ┄")]
        slice.each_with_index do |entry, i|
          selected_entry = top + i == selected
          rows << row(entry, selected: selected_entry, cols: cols)
          rows << activity_row(entry, cols) if selected_entry && !entry.last_activity.to_s.empty?
        end
        rows << @pastel.dim("┄ #{selected + 1}/#{items.size} · Enter opens snapshot ┄") if items.size > MAX_ROWS
        rows
      end

      private

      def live_entries
        Array(@entries.call).select { |entry| live?(entry) }
      rescue StandardError
        []
      end

      def live?(entry)
        %i[running needs_approval blocked_on_human blocked_on_parent stopping].include?(entry.status)
      end

      def row(entry, selected:, cols:)
        marker = selected ? @pastel.cyan("❯") : @pastel.dim("┊")
        label = "#{entry.id} · #{entry.subagent} · #{status_label(entry.status)}"
        LiveRegion.take_first_columns("#{marker} #{label}", cols)
      end

      def activity_row(entry, cols)
        LiveRegion.take_first_columns(@pastel.dim("  #{entry.last_activity}"), cols)
      end

      def status_label(status)
        case status
        when :needs_approval then @pastel.yellow("approval")
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
        return 0 if size <= MAX_ROWS

        if selected < @state[:top]
          selected
        elsif selected >= @state[:top] + MAX_ROWS
          selected - MAX_ROWS + 1
        else
          @state[:top]
        end
      end
    end
  end
end
