# frozen_string_literal: true

require "pastel"

module Rubino
  module UI
    # The {BottomComposer}'s /command + @file completion menu: an inline
    # navigable list rendered in the multi-row live region above the prompt.
    # Candidates come from the shared CompletionSource. The menu auto-opens as
    # you type a `/` or `@` token (Reline parity); Tab also opens/accepts, ↑/↓
    # navigate, Enter accepts, ESC dismisses immediately (and STICKS for the
    # token) leaving the typed buffer untouched.
    #
    # Pure state machine + row formatting: it reads the buffer/cursor the
    # composer passes in and never prints or takes the render mutex — opening,
    # navigation and the accept SPLICE are decided here, but the composer
    # applies the splice to its buffer and owns every redraw.
    class CompletionMenu
      # Most candidate rows shown at once (the list scrolls within this window
      # for longer candidate sets so the prompt is never pushed off-screen).
      MAX_ROWS = 8

      # @param completion_source [CompletionSource, nil] shared completion
      #   discovery (slash commands + @file picker). nil ⇒ the menu is inert
      #   (steering / standalone), so the composer degrades to a plain editor.
      def initialize(completion_source)
        @completion = completion_source
        # Open state: nil when closed, else a Hash with the candidate :items,
        # the :selected index, the :top of the visible window, the :token span
        # being completed (so accept can splice the replacement at the cursor)
        # and the :navigated accept-intent flag.
        @state = nil
        # Sticky ESC-dismiss: once the user presses ESC on an open menu, keep
        # it closed for the CURRENT token instead of re-opening on the next
        # keystroke. Cleared when the token is cleared / on submit / on accept /
        # on an explicit Tab, so a fresh token (or a deliberate Tab) reopens.
        @suppressed = false
      end

      def open?
        !@state.nil?
      end

      # The open menu's candidate items (test/inspection helper), nil when closed.
      def items
        @state && @state[:items]
      end

      # Explicit open (Tab): always clears a sticky ESC-dismiss first — a
      # deliberate Tab reopens a dismissed menu — then opens for the completion
      # context under the cursor, if any. Returns the opened state (truthy; the
      # composer redraws on it), or nil when nothing completes here.
      def open(buffer, cursor)
        @suppressed = false
        ctx = completion_context(buffer, cursor)
        return unless ctx

        items, start, len = ctx
        @state = { items: items, selected: 0, top: 0, start: start, token_len: len,
                   navigated: false }
      end

      # Open / update / close the menu on every edit and cursor move, matching
      # the old Reline autocompletion: typing a leading `/` or `@` token
      # AUTO-opens the dropdown (no Tab needed), refining as the token grows and
      # closing when it no longer completes. Called from every buffer-edit and
      # cursor-move path so the list always tracks the token under the cursor.
      #
      #   * no token under the cursor → close the menu AND clear the sticky
      #     ESC-dismiss flag (a fresh token may auto-open again);
      #   * token present but ESC-dismissed for it → stay closed;
      #   * token with candidates → OPEN a new menu, or UPDATE an open one
      #     (preserving the clamped selection); no candidates → close.
      #
      # The selected index is preserved (clamped) across an update so refining
      # the token doesn't jump the highlight back to the top mid-navigation.
      def auto_update(buffer, cursor)
        ctx = completion_context(buffer, cursor)
        if ctx.nil?
          @state = nil
          @suppressed = false # token cleared: a fresh token can auto-open
          return
        end
        return if @suppressed # ESC stuck this token/argument closed

        items, start, len = ctx
        sel = (@state ? @state[:selected] : 0).clamp(0, items.size - 1)
        @state = { items: items, selected: sel, top: window_top(sel, items.size),
                   start: start, token_len: len,
                   navigated: @state ? @state[:navigated] : false }
      end

      # ↑/↓ within the open menu (routed from the composer's history keys).
      # Arrowing marks the menu as NAVIGATED — an explicit accept intent, so
      # Enter on an empty argument token accepts the highlight instead of
      # submitting the buffer (see #exact_command?).
      def up
        @state[:selected] = [@state[:selected] - 1, 0].max
        navigated_to_selection
      end

      def down
        @state[:selected] = [@state[:selected] + 1, @state[:items].size - 1].min
        navigated_to_selection
      end

      # Accept the highlighted candidate: returns the splice the composer
      # applies — [start, token_len, replacement] where the replacement carries
      # a trailing space (so the next token starts clean, like Reline's append
      # char) — and closes the menu (clearing the sticky dismiss: accepting
      # ends this token; a new one can auto-open).
      def accept_splice
        choice = @state[:items][@state[:selected]].to_s
        splice = [@state[:start], @state[:token_len], "#{choice} "]
        close!
        splice
      end

      # True when the buffer is ALREADY an exact, complete command, so Enter
      # should SUBMIT it rather than accept-and-space (D5/#147). Compares the
      # TOKEN the menu would splice (not the whole buffer, which never matches
      # a bare argument candidate — that's what swallowed Enter on a fully
      # typed `/agents sa_xxx`): submit when the typed token equals a
      # candidate exactly AND that match is the menu's current selection (or
      # the only candidate) — so a partial/ambiguous token (e.g. "/re" with
      # /reasoning + /reset) still accepts the highlight on Enter as before.
      # An EMPTY argument token (`/agents sa_xxx ` with the verb dropdown
      # open) also submits — the buffer is already a complete command and
      # accepting would splice a verb the user never typed — UNLESS the user
      # explicitly arrow-navigated onto a candidate, which is an accept
      # intent. Tab-accept is untouched.
      def exact_command?(buffer)
        return false unless @state

        typed = Array(buffer.chars[@state[:start], @state[:token_len]]).join
        return !@state[:navigated] if typed.empty?

        items = @state[:items]
        return false unless items.include?(typed)

        selected = items[@state[:selected]].to_s
        items.size == 1 || selected == typed
      end

      # Close the menu and clear the sticky ESC-dismiss flag (submit / accept):
      # the next token starts fresh and is free to auto-open again.
      def close!
        @state = nil
        @suppressed = false
      end

      # Lone-ESC dismiss: close AND STICK for the current token so it doesn't
      # pop back on the next keystroke. Cleared when the token changes to nil,
      # on submit/accept, or on an explicit Tab (see #auto_update / #close!).
      def dismiss!
        @state = nil
        @suppressed = true
      end

      # Teardown hide (composer stop/suspend): close the rows without touching
      # the sticky dismiss, so a resume mid-token behaves exactly as before.
      def hide!
        @state = nil
      end

      # The rendered menu rows (the slice in view, the selected one marked with
      # a cyan ❯ and inverse highlight), or [] when no menu is open. House
      # grammar: a dim aside bar leads each row. Candidates with a registered
      # description (BuiltIns/custom command one-liners, the /agents subcommand
      # hints) show it dim in an aligned column next to the name (#39).
      def rows(cols)
        return [] unless @state

        items = @state[:items]
        top   = @state[:top]
        sel   = @state[:selected]
        slice = items[top, MAX_ROWS] || []
        pad   = slice.map { |item| LiveRegion.display_width(item.to_s) }.max.to_i
        rows = slice.each_with_index.map do |item, i|
          candidate_row(item, pad, cols, selected: top + i == sel)
        end
        rows << pastel.dim("┄ #{sel + 1}/#{items.size} ┄") if items.size > MAX_ROWS
        rows
      end

      private

      def navigated_to_selection
        @state[:top] = window_top(@state[:selected], @state[:items].size)
        @state[:navigated] = true
      end

      def candidate_row(item, pad, cols, selected:)
        row = if selected
                "#{pastel.cyan("❯")} #{pastel.inverse(" #{item} ")}"
              else
                "#{pastel.dim("┊")} #{item}"
              end
        desc = description(item, pad, cols)
        if desc
          # Align the description column across rows: the inverse highlight
          # already widens the selected name by 2 (its padding spaces).
          row += (" " * (pad - LiveRegion.display_width(item.to_s) + (selected ? 0 : 2)))
          row += pastel.dim(desc)
        end
        row
      end

      # The dim description for a menu candidate, fitted to the row budget so a
      # long one-liner is right-truncated here instead of the shared row clamp
      # left-truncating the candidate NAME away. nil when the source has none
      # (files, skill names) or the row is too narrow to show one usefully.
      def description(item, pad, cols)
        return nil unless @completion.respond_to?(:description_for)

        desc = @completion.description_for(item).to_s
        return nil if desc.empty?

        budget = cols - pad - 6 # glyph + gaps + the one-column scroll guard
        return nil if budget < 8

        desc.length > budget ? "#{desc[0, budget - 1]}…" : desc
      end

      # Resolve what to complete at the cursor: returns [items, start, len]
      # where +items+ are the candidate strings, +start+ the codepoint index
      # where the splice begins, and +len+ the length of the text the accepted
      # choice replaces — or nil when nothing completes here.
      #
      # Two shapes, in priority order:
      #   1. COMMAND ARGUMENT — the buffer is `/<cmd> <partial>` and <cmd> has a
      #      registered argument source (e.g. `/skills ruby` → skill names). The
      #      partial (possibly empty) is the splice span; this is what lets the
      #      SAME dropdown pick a skill name as it picks a /command or @file.
      #   2. LEADING TOKEN — a `/command` or `@file` token under the cursor
      #      (the original behavior), spliced over the whole token.
      def completion_context(buffer, cursor)
        return nil unless @completion

        if (arg = command_arg_context(buffer, cursor))
          command, partial, start, args = arg
          items = arg_candidates(command, partial, args)
          return nil if items.empty?

          return [items, start, partial.chars.length]
        end

        tok = current_token(buffer, cursor)
        return nil unless tok

        token, start = tok
        items = candidates(token)
        return nil if items.empty?

        [items, start, token.chars.length]
      end

      # The completion TOKEN under the cursor: the leading run of non-space
      # chars from the start of the line up to the cursor, when it begins with
      # / or @. Returns [token, start_index] or nil when the cursor isn't on a
      # token.
      def current_token(buffer, cursor)
        prefix = buffer.chars.first(cursor).join
        # Only the FIRST token on the line completes (a leading /command, or an
        # @mention anywhere the run back to a space starts with @).
        m = prefix.match(%r{(?:\A|\s)([/@]\S*)\z})
        return nil unless m

        [m[1], m.begin(1)]
      end

      # When the buffer is an ARGUMENT position of a slash command — i.e.
      # `/<cmd> [args…] <partial>` with the cursor in the trailing argument —
      # returns [command, partial, partial_start, args] so
      # {#completion_context} can complete it; nil otherwise. +args+ are the
      # COMPLETE arguments before the partial, so a positional source can own a
      # subcommand grammar (`/agents <id> steer|probe|--stop`, #39); whether a
      # position completes at all is the CompletionSource's call (a
      # single-argument command like /skills stops after its first).
      def command_arg_context(buffer, cursor)
        prefix = buffer.chars.first(cursor).join
        m = prefix.match(%r{\A/(\S+)((?:[ \t]+\S+)*)[ \t]+(\S*)\z})
        return nil unless m

        [m[1], m[3], m.begin(3), m[2].split]
      end

      def candidates(token)
        @completion.candidates_for(token)
      rescue StandardError
        []
      end

      # Argument candidates for a slash command (e.g. skill names for `/skills`,
      # ids + steer/probe/--stop for `/agents`), via the CompletionSource.
      # Guarded so a registry hiccup degrades the menu to closed rather than
      # crashing the prompt — same contract as #candidates.
      def arg_candidates(command, partial, args)
        return [] unless @completion.respond_to?(:arg_candidates_for)

        @completion.arg_candidates_for(command, partial, args)
      rescue StandardError
        []
      end

      # The visible window's top index so the selected row stays in view.
      def window_top(selected, size)
        return 0 if size <= MAX_ROWS

        top = @state ? @state[:top] : 0
        top = selected if selected < top
        top = selected - MAX_ROWS + 1 if selected >= top + MAX_ROWS
        top.clamp(0, size - MAX_ROWS)
      end

      def pastel
        @pastel ||= Pastel.new
      end
    end
  end
end
