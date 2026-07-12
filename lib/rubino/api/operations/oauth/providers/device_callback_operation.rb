# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module OAuth
        module Providers
          # POST /v1/oauth/providers/:id/device/callback
          #
          # The client polls this endpoint after showing the user the
          # verification_uri + user_code from {DeviceConnectOperation}.
          #
          # Responses vary by device-code lifecycle:
          #
          #   200 / 201  – user authorized, connection created (token exchanged,
          #                account info fetched, upserted)
          #   202        – still pending (+:retry_after+ hint in body)
          #   400        – expired (+:error+ "expired_token" in body)
          #   4xx / 5xx  – upstream error
          #
          # The caller should respect +:retry_after+ (seconds) and not poll
          # faster than the interval returned by the initial connect.
          #
          # @raise [Rubino::NotFoundError] when no provider is registered.
          # @raise [Rubino::ValidationError] when the provider does not
          #   support device code flow or the body fails validation.
          # @raise [Rubino::UpstreamError] when token exchange fails with a
          #   non-device-code error.
          class DeviceCallbackOperation
            def initialize(registry: ::Rubino::OAuth::Registry, repository: nil)
              @registry   = registry
              @repository = repository
            end

            def call(request)
              id       = request.params.fetch("id")
              provider = @registry.fetch(id)
              _assert_device_code!(provider)

              attrs = request.validate!(Schemas::DeviceCallbackProvider)

              result = provider.poll_device_code(device_code: attrs[:device_code])

              case result
              when :pending
                [202, { status: "pending", retry_after: _default_interval(provider) }]
              when :slow_down
                [202, { status: "pending", retry_after: _slow_down_interval(provider) }]
              when :expired
                [400, { error: "expired_token",
                        message: "The device code has expired. Restart the login." }]
              when Hash
                _exchange_and_persist(provider, result)
              else
                raise UpstreamError,
                      "unexpected device_code poll result: #{result.class}"
              end
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

            def _exchange_and_persist(provider, token)
              ::Rubino::Metrics.counter(
                :oauth_token_exchanges_total,
                provider: provider.id, outcome: "ok"
              ).increment

              info = provider.fetch_account_info(token[:access_token])

              connection = repository.upsert(
                provider:       provider.id,
                account_id:     info[:account_id],
                account_email:  info[:account_email],
                access_token:   token[:access_token],
                refresh_token:  token[:refresh_token],
                expires_at:     token[:expires_at],
                scopes:         token[:scopes],
                metadata:       info[:metadata] || {}
              )

              [201, Serializer.call(connection)]
            rescue StandardError => e
              ::Rubino::Metrics.counter(
                :oauth_token_exchanges_total,
                provider: provider.id, outcome: "error"
              ).increment
              raise UpstreamError.new(
                "device token exchange failed: #{e.class.name}",
                service: provider.id
              )
            end

            def _default_interval(provider)
              provider.respond_to?(:device_interval) ? provider.device_interval : 5
            end

            def _slow_down_interval(provider)
              base = _default_interval(provider)
              base + 5
            end

            def repository
              @repository ||= ::Rubino::OAuth::ConnectionRepository.new
            end
          end
        end
      end
    end
  end
end
