# frozen_string_literal: true

module Rubino
  # UI module namespace and factory.
  # All output in the application flows through a UI adapter.
  module UI
    # "Ruby facet" skin: a red ◆ sweeping back and forth on a 5-cell dim ┄
    # track (the house separator glyph). 12-frame loop @100ms — the facet
    # dwells one extra beat at each end of the sweep.
    FACET_TRACK_CELLS = 5
    FACET_FRAMES = [0, 0, 0, 1, 2, 3, 4, 4, 4, 3, 2, 1].freeze

    # Builds the sweeping ◆┄┄┄┄ track for a single frame of the turn-activity
    # facet. Returns an ANSI-styled string (red ◆ on dim ┄). Callers compose
    # the track with their own text label.
    def self.build_facet_track(tick, pastel)
      pos = FACET_FRAMES[tick % FACET_FRAMES.length]
      (0...FACET_TRACK_CELLS).map do |cell|
        cell == pos ? pastel.red("◆") : pastel.dim("┄")
      end.join
    end

    # Factory method to build the appropriate UI adapter
    def self.build(adapter_name)
      case adapter_name.to_s
      when "cli"
        CLI.new
      when "api"
        API.new
      when "null"
        Null.new
      else
        raise ConfigurationError, "Unknown UI adapter: #{adapter_name}"
      end
    end
  end
end
