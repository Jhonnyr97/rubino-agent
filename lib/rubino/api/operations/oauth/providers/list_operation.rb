# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module OAuth
        module Providers
          # GET /v1/oauth/providers
          # Lists OAuth providers registered at boot, with their default scopes.
          class ListOperation
            def self.call(request)
              new.call(request)
            end

            # Accepts an alternate provider registry for tests.
            def initialize(registry: ::Rubino::OAuth::Registry)
              @registry = registry
            end

            def call(_request)
              providers = @registry.all.map do |p|
                {
                  id: p.id,
                  display_name: p.class.display_name,
                  scopes: p.scopes
                }
              end
              [200, providers]
            end
          end
        end
      end
    end
  end
end
