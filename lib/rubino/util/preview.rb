# frozen_string_literal: true

module Rubino
  module Util
    # Shared truncation helpers for tool output previews — used by both
    # ToolPresentation#preview_arguments (approval prompt) and by tool-level
    # body formatters (post-execution diff/content previews).
    module Preview
      # Truncates +lines+ to +max+ in-place, appending a "[… N more line(s)]"
      # tag when lines are dropped. Returns +lines+ for chaining.
      def self.truncate_lines!(lines, max)
        return lines if lines.size <= max

        dropped = lines.size - max
        lines.replace(lines.first(max))
        lines << "  [… #{dropped} more line(s)]"
        lines
      end
    end
  end
end
