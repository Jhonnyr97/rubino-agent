# frozen_string_literal: true

module Rubino
  module Util
    # Compact, human-readable elapsed-time formatting shared by the agent
    # cards and the /sessions + /agents listings (was copy-pasted into
    # UI::SubagentCards, CLI::ChatCommand, and Commands::Executor).
    #
    # Coarse on purpose: seconds under a minute, then whole minutes, then
    # whole hours — enough to read "how long" at a glance without a clock.
    module Duration
      module_function

      def human_duration(seconds)
        secs = seconds.to_i
        return "#{secs}s" if secs < 60
        return "#{secs / 60}m" if secs < 3600

        "#{secs / 3600}h"
      end
    end
  end
end
