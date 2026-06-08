# frozen_string_literal: true

module Rubino
  # In-process switch that gates two orthogonal concerns from a single name:
  #
  #   :default — tutti i tool registrati, approval rules from config
  #   :plan    — solo tool read-only (read/grep/glob/web/todo/question)
  #   :yolo    — tutti i tool, ApprovalPolicy bypassata (sempre :allow)
  #
  # Lives at the process level intentionally — alpha rule: no premature
  # persistence. A new `rubino chat` boots in :default; an explicit
  # `/mode yolo` or `Modes.set(:yolo)` from the API caller takes effect
  # for the rest of that process. We can move it onto Session later if
  # users actually want it sticky.
  #
  # Boot pinning (#3): the process forgets the active mode on restart, which
  # surprises callers when an external supervisor re-applies config and bounces
  # the process out from under an already-set mode. Rather than introduce
  # on-disk state, the initial mode is read once from the RUBINO_BOOT_MODE env
  # var: an unattended supervisor can pin it in the process environment so a
  # restart comes back up in the same mode it was configured for. Unset (the
  # normal interactive case) keeps the :default boot. An unknown value is
  # ignored so a typo in the environment can never crash boot.
  module Modes
    DEFAULT = :default
    PLAN    = :plan
    YOLO    = :yolo
    ALL     = [DEFAULT, PLAN, YOLO].freeze

    # Tool names allowed in plan mode. Pulled by string against Tool#name
    # in the Registry — see Tools::Registry.enabled_tools. Keep this list
    # in sync with the actual tool names registered in
    # Tools::Registry.register_defaults!; the spec pins both sides.
    READ_ONLY_TOOLS = %w[read grep glob webfetch websearch todowrite question shell_output skill].freeze

    DESCRIPTIONS = {
      DEFAULT => "all tools, approvals from config",
      PLAN    => "read-only tools only, no edits/shell/git",
      YOLO    => "all tools, approvals skipped",
    }.freeze

    class << self
      def current
        @current ||= boot_default
      end

      # Switches the active mode. Returns the new mode symbol. Raises on
      # an unknown name so a typo in a slash command surfaces immediately
      # rather than silently leaving the previous mode in place.
      def set(name)
        sym = name.to_s.downcase.to_sym
        raise ArgumentError, "unknown mode: #{name.inspect} (valid: #{ALL.join(', ')})" unless ALL.include?(sym)
        @current = sym
      end

      # Initial mode for a fresh process. Honours RUBINO_BOOT_MODE so an
      # external supervisor can pin the mode across a restart without any
      # on-disk state; an unset or unknown value falls back to DEFAULT.
      def boot_default
        raw = ENV["RUBINO_BOOT_MODE"]
        return DEFAULT if raw.nil? || raw.strip.empty?

        sym = raw.strip.downcase.to_sym
        ALL.include?(sym) ? sym : DEFAULT
      end

      def reset!
        @current = DEFAULT
      end

      def description(name = current)
        DESCRIPTIONS[name.to_s.downcase.to_sym]
      end

      # Used by Tools::Registry.enabled_tools. Plan is the only mode that
      # filters; default and yolo both pass everything through.
      def allows_tool?(tool_name)
        return true unless current == PLAN
        READ_ONLY_TOOLS.include?(tool_name.to_s)
      end

      # Used by Security::ApprovalPolicy#decide. Yolo short-circuits to
      # :allow before any pattern matching; plan never reaches the policy
      # because the tools it would gate are already filtered out of the
      # registry.
      def skip_approvals?
        current == YOLO
      end
    end
  end
end
