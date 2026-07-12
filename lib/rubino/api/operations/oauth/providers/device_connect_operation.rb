# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module OAuth
        module Providers
          # POST /v1/oauth/providers/:id/device/connect
          #
          # Starts a Device Authorization Grant (RFC 8628) for a provider
          # that includes {Rubino::OAuth::DeviceCodeFlow}. Returns the
          # device_code, user_code, and verification_uri so the client can
          # show them to the user, then polls {DeviceCallbackOperation}
          # until the user authorizes.
          #
          # @raise [Rubino::NotFoundError] when the provider is not registered.
          # @raise [Rubino::ValidationError] when the provider does not
          #   support the device code flow.
          class DeviceConnectOperation
            def initialize(registry: ::Rubino::OAuth::Registry)
              @registry = registry
            end

            def call(request)
              id       = request.params.fetch("id")
              provider = @registry.fetch(id)
              _assert_device_code!(provider)

              attrs = request.validate!(Schemas::DeviceConnectProvider)

              flow = provider.build_device_code_request(scopes: attrs[:scopes])

              [200, flow.merge(provider: provider.id)]
            end

            private

            def _assert_device_code!(provider)
              unless provider.is_a?(::Rubino::OAuth::DeviceCodeFlow)
                raise ValidationError,
                      "provider '#{provider.id}' does not support device code flow"
              end

              return if provider.class.stateless_device_flow?

              raise ValidationError,
                    "provider '#{provider.id}' device login is CLI-only " \
                    "(rubino auth login #{provider.id}) — the HTTP device " \
                    "endpoints don't carry PKCE state across requests"
            end
          end
        end
      end
    end
  end
end
