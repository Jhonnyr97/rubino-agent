# frozen_string_literal: true

module Rubino
  module UI
    # Shared vocabulary for the concise `name hint` tool label.
    #
    # `pick_hint` is the FALLBACK for CallSummary when a tool hasn't declared
    # a `summary` spec — it picks the most-identifying argument in priority
    # order. `label` and `hint` now delegate to CallSummary so the label
    # vocabulary is single-sourced.
    module ToolLabel
      module_function

      # Picks the most-identifying [key, value] pair from a tool's arguments,
      # in priority order. Returns nil when none of the known keys carry a value.
      # `url`/`query` cover the web tools (webfetch/websearch), so a
      # `● webfetch https://…` row names the target instead of a bare `● webfetch`.
      def pick_hint(arguments)
        return nil unless arguments.is_a?(Hash)

        %i[pattern file_path path command url query].each do |k|
          v = arguments[k] || arguments[k.to_s]
          return [k, v] if v && !v.to_s.empty?
        end
        nil
      end

      # The concise, sanitized hint string — delegates to CallSummary when
      # a registered tool is found, falls back to the raw pick_hint otherwise.
      def hint(arguments, max: 60, verbose: false)
        return nil unless arguments.is_a?(Hash)

        picked = pick_hint(arguments)
        return nil unless picked

        raw_key, raw_value = picked
        masked = Util::SecretsMask.mask_value(raw_value, key: raw_key).to_s
        clean  = Util::Output.sanitize_terminal(masked)
        first  = clean.lines.first.to_s.strip
        cap    = verbose ? max * 4 : max
        first.length > cap ? "#{first[0, cap - 3]}..." : first
      end

      # The full `name hint` label. Falls back to the bare tool name when the
      # tool has no identifying argument.
      def label(name, arguments, max: 60, verbose: false)
        h = hint(arguments, max: max, verbose: verbose)
        h && !h.empty? ? "#{name} #{h}" : name.to_s
      end
    end
  end
end
