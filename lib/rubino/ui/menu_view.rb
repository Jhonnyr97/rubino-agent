# frozen_string_literal: true

require "pastel"

module Rubino
  module UI
    # The single presentational renderer shared by the two navigable dropdowns
    # — the {CompletionMenu} (`/` command + `@file` palette) and the {AgentMenu}
    # (`↓` live-subagent picker). It owns ONLY the look: the scroll-window slice,
    # the `❯`/`┊` glyph rows, the cyan-`❯` + inverse-video highlight, an optional
    # header, the optional per-row sub-line, and the overflow footer. Neither
    # menu's state machine lives here — each keeps its own filtering / `◂ main` /
    # sticky-Esc / self-close logic and just hands MenuView its already-decided
    # rows, so a user who learns one dropdown recognises the other (#562).
    #
    # A +row+ descriptor is a Hash:
    #   * :label    — the visible text (caller pre-colours any status spans);
    #   * :desc     — an optional dim description shown in an aligned right
    #                 column (the command menu's one-liners), or nil;
    #   * :sub      — an optional dim sub-line drawn UNDER the row when selected
    #                 (the picker's live-activity line), or nil;
    #   * :pad_key  — the plain string measured for the :desc column alignment
    #                 (defaults to :label); descriptions align on the widest.
    module MenuView
      module_function

      # Render the box: slice +rows+ to the +top+/+max_rows+ window, mark the
      # +selected+ row with the cyan ❯ + inverse highlight (others a dim ┊),
      # prepend a dim `┄ header ┄` when given, and append the dim
      # `┄ <n>/<total> · <hints> ┄` footer when the list overflows the window.
      #
      # @param rows [Array<Hash>] the full descriptor list (see the class note)
      # @param cols [Integer] the available terminal columns
      # @param window [Hash] the scroll window: +:selected+ index, +:top+ index
      #   of the first visible row, and +:max_rows+ (the window height)
      # @param header [String, nil] optional header label (wrapped `┄ … ┄`)
      # @param hints [String, nil] optional footer key hints (e.g. "Enter · Esc")
      def render(rows, cols, window:, header: nil, hints: nil)
        return [] if rows.empty?

        selected, top, max_rows = window.values_at(:selected, :top, :max_rows)
        slice = rows[top, max_rows] || []
        pad   = slice.map { |r| LiveRegion.display_width(safe(r[:pad_key] || r[:label])) }.max.to_i

        out = []
        out << pastel.dim("┄ #{header} ┄") if header
        slice.each_with_index do |row, i|
          chosen = top + i == selected
          out << format_row(row, pad, cols, selected: chosen)
          out << sub_row(row[:sub], cols) if chosen && row[:sub] && !row[:sub].to_s.empty?
        end
        out << footer(selected, rows.size, hints) if rows.size > max_rows
        out
      end

      # The visible-window top index keeping +selected+ in view, given the
      # current +top+. Shared by both menus' scroll math so the window never
      # jumps the highlight out of view (used to be re-implemented in each).
      def window_top(selected, size, top, max_rows)
        return 0 if size <= max_rows

        top = selected if selected < top
        top = selected - max_rows + 1 if selected >= top + max_rows
        top.clamp(0, size - max_rows)
      end

      def format_row(row, pad, cols, selected:)
        label = safe(row[:label])
        line = if selected
                 "#{pastel.cyan("❯")} #{pastel.inverse(" #{label} ")}"
               else
                 "#{pastel.dim("┊")} #{label}"
               end
        line = append_desc(line, row, pad, selected: selected) if row[:desc]
        LiveRegion.take_first_columns(line, cols)
      end

      # Append the dim description in an aligned column. The inverse highlight
      # widens the selected label by 2 (its padding spaces), so the unselected
      # rows get +2 to line their descriptions up with the selected one.
      def append_desc(line, row, pad, selected:)
        plain = safe(row[:pad_key] || row[:label])
        line += " " * (pad - LiveRegion.display_width(plain) + (selected ? 0 : 2))
        line + pastel.dim(safe(row[:desc]))
      end

      def sub_row(sub, cols)
        LiveRegion.take_first_columns(pastel.dim("  #{safe(sub)}"), cols)
      end

      # CWE-150 render-sink defense. Menu LABELS/descs/subs are UNTRUSTED — the
      # `@file` palette feeds raw workspace filenames straight in, so a file
      # named with embedded escapes (`\e[2J` clear-screen, `\e]0;…\a` OSC
      # title-set, `\e[?1049h` alt-screen, CR/BEL) would otherwise be rendered
      # VERBATIM to the TTY the instant the picker opens — pre-tool, no approval,
      # no gesture (#563). Neutralize every dangerous control byte at THIS
      # chokepoint so it covers ALL label sources (the @file completer, the /
      # command menu, the agent picker). Use the SGR-preserving variant because
      # callers legitimately pre-colour status spans (e.g. the picker's live
      # glyph) — those inert color codes survive; everything that can move the
      # cursor, repaint, set the title, or write the clipboard is caret-ised.
      def safe(text)
        Rubino::Util::Output.sanitize_terminal_keep_sgr(text.to_s)
      end

      def footer(selected, total, hints)
        body = "#{selected + 1}/#{total}"
        body += " · #{hints}" if hints && !hints.empty?
        pastel.dim("┄ #{body} ┄")
      end

      def pastel
        @pastel ||= Pastel.new
      end
    end
  end
end
