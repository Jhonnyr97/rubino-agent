# frozen_string_literal: true

module Rubino
  module UI
    # The /probe (#58) and /agents probe (#146) wait indicator: reuse the UI's
    # thinking-row machinery (UI::CLI) while a billed ephemeral peek runs, and
    # stay silent on Null/API adapters or piped stdout. Mixed into both the
    # CLI::ChatCommand and Commands::Executor probe paths, which carried a
    # byte-identical pair of guards.
    module ProbeWaitIndicator
      def probe_thinking_started(ui)
        return unless $stdout.tty? && ui.respond_to?(:thinking_started)

        ui.thinking_started
      end

      def probe_thinking_finished(ui)
        ui.thinking_finished if ui.respond_to?(:thinking_finished)
      end
    end
  end
end
