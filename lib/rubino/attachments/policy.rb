# frozen_string_literal: true

module Rubino
  module Attachments
    # Reads the secure-by-default knobs from config (attachments.policy). One
    # auditable surface; defaults live in Config::Defaults on the secure
    # branch, explicit user config always wins (Configuration merges over
    # defaults). No state of its own -- just a typed view over the config hash.
    module Policy
      module_function

      def config
        Rubino.configuration.dig("attachments", "policy") || {}
      end

      def max_file_bytes
        Integer(config["max_file_bytes"] || 26_214_400)
      end

      def inline_text_budget_bytes
        Integer(config["inline_text_budget_bytes"] || 100_000)
      end

      # Kinds the handler is allowed to process. Anything outside the list is
      # skipped (fail-closed). Symbols for easy comparison with classify.
      def allow_kinds
        Array(config["allow_kinds"] || %w[image text document archive binary])
          .map { |k| k.to_s.to_sym }
      end

      def allow_kind?(kind)
        allow_kinds.include?(kind.to_sym)
      end

      # Egress kill-switch for routing an image to an EXTERNAL auxiliary vision
      # model (the `vision` tool). On by default to preserve aux-vision
      # behaviour; an operator sets it false to forbid shipping image bytes
      # off-host. Only an explicit `false` disables egress (opt-out model).
      def aux_vision_egress?
        config["aux_vision_egress"] != false
      end
    end
  end
end
