# frozen_string_literal: true

module Rubino
  module UI
    # Attention notifications for the moments the agent needs human eyes:
    # a long agentic turn finishing, an approval prompt parking the run on a
    # human decision, or a background subagent blocking on the human (an
    # escalated ask_parent).
    #
    # Channels — mirroring the dominant pattern across coding agents (Claude
    # Code's terminal bell + hooks, Codex's notify hook, aider's
    # --notifications):
    #   * terminal bell (BEL, "\a") — default on. BEL never moves the cursor,
    #     so it is safe even while the bottom composer owns the screen; it is
    #     still routed to the composer's REAL output (never the StdoutProxy,
    #     whose partial-line buffer would re-ring the byte on every repaint)
    #     and NEVER into a pipe.
    #   * OSC 9 ("\e]9;msg\a") — additionally emitted on iTerm2
    #     (TERM_PROGRAM=iTerm.app), which renders it as a native macOS
    #     notification.
    #   * notifications.command — an optional shell command spawned
    #     NON-BLOCKING and best-effort per event with RUBINO_EVENT
    #     (turn_finished | needs_approval | blocked) and RUBINO_MESSAGE in
    #     its environment; failures are swallowed to the structured log.
    #     Covers osascript / notify-send users.
    #
    # Spam control: events landing within COALESCE_SECONDS of the last
    # emitted one are dropped, so a burst (several children blocking at once)
    # rings at most once.
    class Notifier
      # Event names the command hook sees via RUBINO_EVENT.
      EVENTS = %i[turn_finished needs_approval blocked].freeze
      # Burst window: events within this many seconds of the last emitted
      # notification coalesce (are dropped).
      COALESCE_SECONDS = 1.0

      # @param config [Config::Configuration, nil] resolved lazily per event
      #   from Rubino.configuration when nil, so a config reload (or a
      #   test-injected configuration) is honored without rebuilding the UI.
      def initialize(config: nil)
        @config          = config
        @mutex           = Mutex.new
        @last_emitted_at = nil
      end

      # A turn ended after +seconds+. Quick turns stay silent
      # (notifications.min_turn_seconds): focus detection is unreliable in
      # plain terminals, so duration is the proxy for "the human probably
      # looked away".
      def turn_finished(seconds)
        return if seconds.nil? || seconds.to_f < min_turn_seconds

        notify(:turn_finished, "turn finished after #{seconds.to_i}s")
      end

      # An approval prompt is parked on the human — the main agent's confirm
      # card, or a background child flipped to :needs_approval.
      def needs_approval(message = "approval required")
        notify(:needs_approval, message)
      end

      # A background child is blocked on the human (the ⛔ escalated
      # ask_parent banner).
      def blocked(message = "a subagent is waiting on you")
        notify(:blocked, message)
      end

      # Emits one notification through every enabled channel. Best-effort: a
      # channel failure is logged and never raised into the turn.
      def notify(event, message)
        return unless enabled?
        return unless mark_emittable!

        emit_bell(message)
        spawn_command(event, message)
      rescue StandardError => e
        log_failure(e)
      end

      private

      # Coalescing gate: claims the emission slot, or returns false when the
      # last notification fired under COALESCE_SECONDS ago.
      def mark_emittable!
        @mutex.synchronize do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return false if @last_emitted_at && (now - @last_emitted_at) < COALESCE_SECONDS

          @last_emitted_at = now
          true
        end
      end

      def emit_bell(message)
        return unless bell_enabled?

        sink = bell_sink
        return unless sink

        payload = +"\a"
        payload << "\e]9;#{osc_safe(message)}\a" if iterm?
        sink.write(payload)
        sink.flush if sink.respond_to?(:flush)
      rescue StandardError => e
        log_failure(e)
      end

      # The REAL terminal the bell may ring on, or nil (never bell into a
      # pipe). While a composer owns the screen $stdout is the StdoutProxy
      # (tty? false by design); the composer's +output+ is the real IO it
      # captured before the swap.
      def bell_sink
        out = BottomComposer.current&.output || $stdout
        return out if out.respond_to?(:tty?) && out.tty?

        nil
      rescue StandardError
        nil
      end

      def iterm?
        ENV["TERM_PROGRAM"] == "iTerm.app"
      end

      # OSC payload hygiene: a control byte (including the BEL terminator
      # itself) inside the message would cut or corrupt the sequence.
      def osc_safe(message)
        message.to_s.gsub(/[[:cntrl:]]/, " ")[0, 200]
      end

      # Fire-and-forget command hook: spawned detached with the event in its
      # env, stdio nulled so it can never write into the composer's screen.
      def spawn_command(event, message)
        cmd = command
        return unless cmd

        pid = Process.spawn(
          { "RUBINO_EVENT" => event.to_s, "RUBINO_MESSAGE" => message.to_s },
          cmd,
          in: File::NULL, out: File::NULL, err: File::NULL
        )
        Process.detach(pid)
      rescue StandardError => e
        log_failure(e)
      end

      def log_failure(error)
        Rubino.logger.debug(event: "ui.notifier.failed", error: error.message)
      rescue StandardError
        nil
      end

      def config
        @config || Rubino.configuration
      end

      def enabled?         = config.notifications_enabled?
      def bell_enabled?    = config.notifications_bell?
      def command          = config.notifications_command
      def min_turn_seconds = config.notifications_min_turn_seconds
    end
  end
end
