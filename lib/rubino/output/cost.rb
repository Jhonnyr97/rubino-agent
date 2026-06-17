# frozen_string_literal: true

module Rubino
  module Output
    # Best-effort USD cost for a turn's token usage, for the machine-readable
    # `total_cost_usd` field (Claude-Code-aligned).
    #
    # Pricing is sourced from ruby_llm's model registry when the model is known
    # there (input/output price per million tokens). Most self-hosted / MiniMax
    # deployments are NOT in that registry, so there is no price to apply — in
    # that case we return nil and the serializer emits `total_cost_usd: null`
    # rather than a fabricated number. This is the honest counterpart to Claude
    # Code, which always has its own pricing table.
    module Cost
      module_function

      # @return [Float, nil] USD cost, or nil when the model's pricing is unknown.
      def for_usage(model_id:, input_tokens:, output_tokens:)
        return nil if model_id.to_s.empty?

        model = lookup(model_id)
        return nil unless model

        in_price  = price(model, :input_price_per_million)
        out_price = price(model, :output_price_per_million)
        return nil if in_price.nil? && out_price.nil?

        cost = (input_tokens.to_i / 1_000_000.0 * in_price.to_f) +
               (output_tokens.to_i / 1_000_000.0 * out_price.to_f)
        cost.round(6)
      rescue StandardError
        # A pricing lookup detail must never fail the run or corrupt the JSON.
        nil
      end

      def lookup(model_id)
        return nil unless defined?(RubyLLM)

        RubyLLM.models.find(model_id)
      rescue StandardError
        nil
      end

      def price(model, method_name)
        return nil unless model.respond_to?(method_name)

        value = model.public_send(method_name)
        value&.to_f
      end
    end
  end
end
