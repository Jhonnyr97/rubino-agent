# frozen_string_literal: true

module Rubino
  module CLI
    module Chat
      # Tails a LIVE subagent while the REPL is ATTACHED to its view (the
      # `↓ + Enter` drill-in). The one-time replay #attach_agent_view does is a
      # snapshot — it shows the transcript as it stood at attach time and then
      # goes stale while the sub keeps working. This watcher closes that gap: a
      # low-frequency ticker thread (modelled on IdleCardHost#start_ticker) that
      # each tick paints the sub's NEW activity through the same focused-view seam
      # the replay uses, so the attached screen behaves like the main agent's own
      # scrollback + live-tail (committed deltas append; the "doing now" row
      # repaints in place) and stops cleanly the moment the sub finishes or the
      # user detaches.
      #
      # The ticker runs on its OWN thread but every paint goes through the
      # composer's render mutex (set_partial / print_above under @render), exactly
      # like IdleCardHost. It NEVER paints once the REPL has detached or switched
      # to another agent: each tick re-checks `still_attached?` (the host's
      # @attached_id == our id) under that discipline. A paint is cosmetic — any
      # error kills only the ticker, never the REPL.
      class AttachedAgentWatcher
        # How often (seconds) the attached view re-tails the focused sub. Tight
        # enough to feel live (the sub commits a turn / updates its activity
        # field) but cheap — a tick that finds no new committed messages and an
        # unchanged live tail repaints nothing.
        WATCH_TICK = 0.4

        # The terminal statuses (the sub's worker thread is done). Mirrors
        # BackgroundTasks#terminal_status? — inlined here since that helper is
        # private and this is its only caller, the same way handle_attached_input
        # inlines the live set.
        TERMINAL_STATES = %i[completed failed stopped cancelled].freeze

        # How many recent `✓ verb · hint` activity rows the live "doing now" block
        # shows under its header — enough to convey intra-turn progress on a long
        # turn that hasn't committed yet, few enough to stay within the composer's
        # transient-row budget and not crowd the committed transcript above.
        MAX_LIVE_ROWS = 3

        # @param host           the ChatCommand — supplies session_resolver,
        #                        with_focused_view_replay, pastel and the
        #                        @attached_id focus guard.
        # @param id             the subagent id this watcher is pinned to.
        # @param ui             the UI the focused view commits through.
        # @param rendered_count how many of entry.messages the initial replay
        #                       already committed (the diff baseline).
        def initialize(host:, id:, ui:, rendered_count:)
          @host           = host
          @id             = id
          @ui             = ui
          @rendered_count = rendered_count
          @last_tail      = nil
          @last_composer  = nil
        end

        # Start the ticker thread. A no-op off a composer (plain TTY / pipe /
        # tests) where there is nothing to tail in place. Returns the Thread (or
        # nil) so the caller can stop it on detach.
        #
        # Each tick RE-RESOLVES the composer that owns the screen NOW
        # (UI::BottomComposer.current) rather than pinning the one present at
        # attach time: the REPL rebuilds a fresh composer every idle pass, so a
        # pinned reference would go stale the instant the loop recreates one and
        # the live tail would silently stop painting (#82). The focus guard is the
        # persistent host @attached_id, not composer identity.
        def start
          return nil unless UI::BottomComposer.current

          Thread.new do
            loop do
              sleep(WATCH_TICK)
              composer = UI::BottomComposer.current
              break unless still_attached?(composer)

              tick(composer)
              break unless live?
            end
          rescue StandardError => e
            # Exit on any error so a hiccup never crashes the REPL. This rescue
            # only ever fires once (the loop is already dead here), so log the
            # swallowed bug once rather than silently freezing the live tail for
            # the rest of the attach.
            Rubino.logger.warn(event: "cli.attached_agent_watcher.crashed",
                               error: e.message, error_class: e.class.name)
            nil
          end
        end

        private

        # One refresh of the attached view, through the suppression-exempt seam so
        # the slice-3 main-render gate doesn't drop these focused paints.
        def tick(composer)
          entry = Tools::BackgroundTasks.instance.find(@id)
          return unless entry

          # The REPL rebuilds the composer every idle pass (#82): a fresh one has
          # an empty transient row, but @last_tail still holds the prior frame, so
          # an unchanged-status tick would SKIP repainting and leave the new
          # composer with no live tail until the status text happens to change.
          # Drop the cache on a composer changeover so the ⟂ frame lands on the
          # new screen immediately.
          unless composer.equal?(@last_composer)
            @last_tail     = nil
            @last_composer = composer
          end

          @host.send(:with_focused_view_replay, composer) do
            commit_message_delta(entry)
            if terminal?(entry)
              commit_terminal_marker(entry, composer)
            else
              paint_live_tail(entry, composer)
            end
          end
        rescue StandardError
          nil # a single tick's paint is cosmetic — never break the ticker.
        end

        # COMMITTED delta (append-only, reliable): entry.messages grows by a whole
        # message per committed turn, so replay ONLY the tail past what we have
        # already shown and advance the cursor. Nothing new ⇒ nothing painted.
        def commit_message_delta(entry)
          messages = Array(entry.messages)
          return if messages.size <= @rendered_count

          @host.send(:session_resolver)
               .replay_messages(@ui, messages[@rendered_count..], banner: false)
          @rendered_count = messages.size
        end

        # LIVE tail (transient): one in-place row of what the sub is doing NOW,
        # painted through the composer's transient-row seam (set_partial, the
        # SAME row the status spinner / live tail use) so it updates without
        # stacking. set_partial is the main-render gate's exempt path while we're
        # inside with_focused_view_replay (@replaying), so the frame lands.
        # Skipped when the text is unchanged so a quiet gap costs nothing.
        def paint_live_tail(entry, composer)
          frame = live_tail_frame(entry)
          return if frame == @last_tail

          @last_tail = frame
          composer.set_partial(frame)
        end

        # The live "doing now" block. A subagent's COMMITTED transcript
        # (entry.messages) only grows when a turn PERSISTS — so a long turn that
        # fires many tool calls before it commits would leave #commit_message_delta
        # with nothing to show and the attached view frozen (the user's "rimane
        # frizzato"). The registry's per-TOOL fields (tool_count + activity_log)
        # advance live within that turn, so surface them here as a transient block:
        # a `⟂ <sub> · <status> · <n> tools` header over the last few `✓ verb ·
        # hint` activity rows. It repaints in place (set_partial) whenever the
        # activity changes, so intra-turn progress shows before the turn commits.
        # Falls back to last_activity / output_tail when the ring is empty.
        def live_tail_frame(entry)
          pastel = @host.send(:pastel)
          tools  = entry.tool_count.to_i
          head   = "⟂ #{entry.subagent} · #{entry.status} · #{tools} tool#{"s" if tools != 1}"
          recent = Array(entry.activity_log).last(MAX_LIVE_ROWS)
          if recent.empty?
            activity = entry.last_activity.to_s
            activity = Array(entry.output_tail).reject(&:empty?).last.to_s if activity.empty?
            head += " · #{activity}" unless activity.empty?
            return pastel.dim(head)
          end
          pastel.dim(([head] + recent.map { |row| "  #{row}" }).join("\n"))
        end

        # On the sub reaching a terminal state while attached: clear the live row,
        # commit a final marker, and let the ticker stop (live? is now false). The
        # snapshot stays on screen — the user detaches deliberately (← / /back),
        # matching the existing handle_attached_input terminal handling.
        def commit_terminal_marker(entry, composer)
          composer.set_partial("") # clear the transient "doing now" row.
          return if @terminal_marked

          @terminal_marked = true
          @ui.info(@host.send(:pastel).dim(
                     "✓ #{@id} finished · #{entry.status} — press ← or /back to return to main"
                   ))
        end

        # The ticker keeps going only while the sub still holds a live thread.
        def live?
          entry = Tools::BackgroundTasks.instance.find(@id)
          !entry.nil? && !terminal?(entry)
        end

        def terminal?(entry)
          TERMINAL_STATES.include?(entry.status)
        end

        # Still attached to THIS sub AND a composer still owns the screen.
        # Re-checked every tick so the watcher never paints after a detach or a
        # switch to another agent (each gets its own watcher). The guard is the
        # PERSISTENT host @attached_id, not composer identity: the REPL rebuilds
        # the composer every idle pass, so pinning a specific instance would
        # falsely report "detached" and freeze the live tail (#82). A nil composer
        # (no TTY) stops the ticker.
        def still_attached?(composer)
          !composer.nil? &&
            @host.instance_variable_get(:@attached_id) == @id
        end
      end
    end
  end
end
