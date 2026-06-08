# frozen_string_literal: true

require "ruby_llm"

module Rubino
  module API
    module Operations
      module Models
        # GET /v1/models — returns the model catalog from ruby_llm.
        # The source defaults to RubyLLM.models.all but accepts any callable
        # returning an enumerable of model objects/hashes for tests.
        class ListOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate model source (callable) for tests.
          def initialize(model_source: nil)
            @model_source = model_source || -> { RubyLLM.models.all }
          end

          def call(_request)
            models = @model_source.call.map do |m|
              {
                id: model_id(m),
                provider: m.respond_to?(:provider) ? m.provider.to_s : nil,
                context_window: m.respond_to?(:context_window) ? m.context_window : nil
              }
            end
            [200, models]
          end

          private

          def model_id(model)
            return model.id if model.respond_to?(:id)
            return model[:id] if model.is_a?(Hash)

            model.to_s
          end
        end
      end
    end
  end
end
