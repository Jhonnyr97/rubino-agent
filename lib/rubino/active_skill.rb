# frozen_string_literal: true

module Rubino
  # In-process switch holding the ONE skill the user has pinned active for the
  # session (MVP: one at a time). Mirrors Rubino::Modes: a process-level slot,
  # set via `/skills <name>` (the completion-dropdown picker) and cleared via
  # `/skills none`. The active skill is force-loaded into the system prompt each
  # turn (Context::PromptAssembler), so the model actually uses it — not just a
  # cosmetic chip.
  #
  # Lives at the process level intentionally — alpha rule: no premature
  # persistence. A fresh `rubino chat` boots with NO active skill; an explicit
  # `/skills <name>` takes effect for the rest of that process. We can move it
  # onto Session later if users want it sticky across restarts.
  #
  # The sentinel "none" (and the `✗ none` dropdown entry) clears the slot.
  module ActiveSkill
    # The dropdown/CLI sentinel that clears the active skill.
    NONE = "none"

    class << self
      # The active skill name (String), or nil when none is pinned.
      attr_reader :current

      # Pins +name+ as the active skill. A nil/empty/"none" clears it. Returns
      # the new value (the name String, or nil when cleared). The caller is
      # responsible for validating the name against the registry BEFORE calling
      # this — ActiveSkill is a dumb slot, like Modes.
      def set(name)
        normalized = name.to_s.strip
        @current = normalized.empty? || normalized.casecmp?(NONE) ? nil : normalized
      end

      # Clears the active skill (the `/skills none` / `✗ none` path).
      def clear
        @current = nil
      end

      # True when a skill is pinned.
      def active?
        !@current.nil?
      end

      # Test/teardown hook. Not part of the public API.
      def reset!
        @current = nil
      end
    end
  end
end
