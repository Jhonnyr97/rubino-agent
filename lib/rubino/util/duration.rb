# frozen_string_literal: true

module Rubino
  module Util
    # Compact, human-readable elapsed-time formatting shared by the agent
    # cards and the /sessions + /agents listings (was copy-pasted into
    # UI::SubagentCards, CLI::ChatCommand, and Commands::Executor).
    #
    # Coarse on purpose for AGES ("5m ago" scans better than a clock): seconds
    # under a minute, then whole minutes, then whole hours. A LIVE counter
    # (a still-running subagent's elapsed) passes precise: true so it carries
    # the next-smaller unit and visibly advances every second instead of
    # sitting on a whole-minute value for ~59s and reading as frozen (#44).
    module Duration
      module_function

      def human_duration(seconds, precise: false)
        secs = seconds.to_i
        return "#{secs}s" if secs < 60
        return format(precise ? "%dm%02ds" : "%dm", secs / 60, secs % 60) if secs < 3600

        format(precise ? "%dh%02dm" : "%dh", secs / 3600, (secs % 3600) / 60)
      end
    end
  end
end
