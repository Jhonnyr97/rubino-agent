# frozen_string_literal: true

require_relative "bottom_composer"

module Rubino
  module UI
    # The /probe (#58) and /agents probe (#146) wait indicator: reuse the UI's
    # thinking-row machinery (UI::CLI) while a billed ephemeral peek runs, and
    # stay silent on Null/API adapters or piped stdout. Mixed into both the
    # CLI::ChatCommand and Commands::Executor probe paths, which carried a
    # byte-identical pair of guards.
    #
    # The peek is SYNCHRONOUS (seconds of model wait) and runs at the idle REPL
    # with no live composer, so keystrokes typed during it used to smear onto the
    # thinking row — there was no `❯` to echo into (#221). To own input the same
    # way a streaming turn does, the wait now runs under a transient bottom
    # composer: it draws a real `❯`, its reader thread buffers keystrokes, and
    # the thinking ticker paints into its transient row via #set_partial (the
    # #169 seam) instead of colliding with the input. Anything typed is recovered
    # into the next idle prompt's draft, so input is never lost.
    module ProbeWaitIndicator
      def probe_thinking_started(ui)
        return unless $stdout.tty? && ui.respond_to?(:thinking_started)

        # Own the bottom of the screen for the wait so typed input lands in a
        # visible `❯` instead of smearing onto the ticker row (#221). Started
        # BEFORE the ticker so #thinking_started paints into the composer's
        # transient row. A standalone editor (no completion/history wiring) — it
        # only needs to echo input and host the ticker. Best-effort: a terminal
        # that can't host a raw composer (no real device, sized double) just
        # keeps the old ticker-only wait — never break the probe.
        @probe_composer = build_probe_composer
        ui.thinking_started
      end

      def probe_thinking_finished(ui)
        ui.thinking_finished if ui.respond_to?(:thinking_finished)
        composer = @probe_composer
        @probe_composer = nil
        return unless composer

        # Hand whatever the user typed during the wait to the next idle prompt as
        # a draft, so the buffered text reappears in `❯` after the peek (no data
        # loss). Read the buffer before #stop tears the composer down and
        # restores cooked mode + a clean line. Best-effort: tearing down a
        # degraded composer must never break the probe (mirrors the start guard).
        typed = begin
          composer.buffer.dup
        rescue StandardError
          nil
        end
        begin
          composer.stop
        rescue StandardError
          nil
        end
        ui.stash_probe_draft(typed) if typed && !typed.empty? && ui.respond_to?(:stash_probe_draft)
      end

      private

      # Builds and starts the transient probe composer, or nil when the terminal
      # can't host a raw input reader (no real stdin/stdout device — piped, or a
      # test double). Best-effort: a failed start degrades to the old ticker-only
      # wait rather than breaking the probe.
      def build_probe_composer
        return nil unless $stdin.respond_to?(:tty?) && $stdin.tty?

        BottomComposer.new(input_queue: [], echo: :prompt).start
      rescue StandardError
        nil
      end
    end
  end
end
