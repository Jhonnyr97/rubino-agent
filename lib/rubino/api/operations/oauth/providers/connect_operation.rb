# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module OAuth
        module Providers
          # POST /v1/oauth/providers/:id/connect
          #
          # Builds a PKCE authorize request for the provider and returns
          # { authorize_url, state, code_verifier, provider }. The client
          # persists state + code_verifier between connect and callback;
          # rubino stays stateless on the OAuth flow itself.
          #
          # @raise [Rubino::NotFoundError] when no provider is registered for +:id+.
          # @raise [Rubino::ValidationError] when the body fails Schemas::ConnectProvider.
          class ConnectOperation
            def self.call(request)
              new.call(request)
            end

            # Accepts an alternate provider registry for tests.
            def initialize(registry: ::Rubino::OAuth::Registry)
              @registry = registry
            end

            def call(request)
              id = request.params.fetch("id")
              provider = @registry.fetch(id)
              attrs = request.validate!(Schemas::ConnectProvider)

              flow = provider.build_authorize_request(
                redirect_uri: attrs[:redirect_uri],
                scopes: attrs[:scopes]
              )

              [200, flow.merge(provider: provider.id)]
            end
          end
        end
      end
    end
  end
end
