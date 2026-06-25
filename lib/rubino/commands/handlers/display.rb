# frozen_string_literal: true

module Rubino
  module Commands
    module Handlers
      # Terminal-width + word-wrap helpers shared by the list-rendering handlers
      # (/mcp, /skills, /memory, /help). Mixed in rather than duplicated per
      # handler — every copy of #terminal_width was byte-identical, and #mcp,
      # #skills and #memory carried the exact same #wrap_skill_line. (/help keeps
      # its own #wrap_help_desc, which wraps to a caller-supplied width with no
      # head/indent column, but shares #terminal_width.)
      module Display
        private

        # The current terminal width (columns), defaulting to 80 off a tty or on
        # any console hiccup.
        def terminal_width
          cols = IO.console&.winsize&.last
          cols&.positive? ? cols : 80
        rescue StandardError
          80
        end

        # Wraps "<head><description>" to the terminal width, breaking only on
        # whitespace, with continuation lines indented to the description column.
        def wrap_skill_line(head, description)
          width = terminal_width
          indent = " " * head.length
          avail  = [width - head.length, 20].max

          lines = []
          current = +""
          description.split(/\s+/).each do |word|
            candidate = current.empty? ? word : "#{current} #{word}"
            if candidate.length > avail && !current.empty?
              lines << current
              current = word.dup
            else
              current = candidate
            end
          end
          lines << current unless current.empty?
          lines = [""] if lines.empty?

          lines.each_with_index.map { |line, i| (i.zero? ? head : indent) + line }
        end
      end
    end
  end
end
