# frozen_string_literal: true

module Rubino
  module UI
    # Shared vocabulary for the concise `name hint` tool label used across
    # adapters — the interactive `● edit foo.rb` card open-row (UI::CLI) AND the
    # non-interactive one-shot stderr trace (UI::HeadlessTrace) draw their hint
    # from here so the two never drift. The hint is the single most-identifying
    # argument (pattern / file_path / path / command), secrets-masked and
    # terminal-sanitized so an untrusted filename/command can never drive the
    # terminal from a label row (R3C-1, CWE-150).
    module ToolLabel
      module_function

      # Picks the most-identifying [key, value] pair from a tool's arguments,
      # in priority order. Returns nil when none of the known keys carry a value.
      def pick_hint(arguments)
        return nil unless arguments.is_a?(Hash)

        %i[pattern file_path path command].each do |k|
          v = arguments[k] || arguments[k.to_s]
          return [k, v] if v && !v.to_s.empty?
        end
        nil
      end

      # The concise, sanitized hint string for a tool's arguments — the first
      # line, secrets-masked, escape-stripped, truncated to `max` chars. Returns
      # nil when there's no identifying argument. `verbose:` raises the cap so a
      # `--verbose` one-shot trace can show fuller args.
      def hint(arguments, max: 60, verbose: false)
        picked = pick_hint(arguments)
        return nil unless picked

        raw_key, raw_value = picked
        masked = Util::SecretsMask.mask_value(raw_value, key: raw_key).to_s
        clean  = Util::Output.sanitize_terminal(masked)
        first  = clean.lines.first.to_s.strip
        cap    = verbose ? max * 4 : max
        first.length > cap ? "#{first[0, cap - 3]}..." : first
      end

      # The full `name hint` label (e.g. `edit foo.rb`, `bash npm test`,
      # `read README.md`). Falls back to the bare tool name when the tool has no
      # identifying argument.
      def label(name, arguments, max: 60, verbose: false)
        h = hint(arguments, max: max, verbose: verbose)
        h && !h.empty? ? "#{name} #{h}" : name.to_s
      end
    end
  end
end
