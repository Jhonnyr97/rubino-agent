# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module OAuth
        module Providers
          # POST /v1/oauth/providers/:id/callback
          #
          # Client posts back code + state + code_verifier (plus expected_state
          # it kept from connect). We constant-time-compare state, exchange the
          # code, fetch account info, upsert by (provider, account_id) with
          # encrypted tokens, and return the connection. Exchange outcomes
          # bump oauth_token_exchanges_total {ok|error}.
          #
          # @return [[Integer, Hash]] 201 + serialized connection (tokens stripped).
          # @raise [Rubino::NotFoundError] when no provider is registered for +:id+.
          # @raise [Rubino::ValidationError] when the body fails Schemas::CallbackProvider or state mismatches.
          # @raise [Rubino::UpstreamError] when the provider's token exchange raises.
          class CallbackOperation
            def self.call(request)
              new.call(request)
            end

            # Accepts an alternate provider registry and connection repository for tests.
            def initialize(registry: ::Rubino::OAuth::Registry, repository: nil)
              @registry = registry
              @repository = repository
            end

            def call(request)
              id = request.params.fetch("id")
              provider = @registry.fetch(id)
              attrs = request.validate!(Schemas::CallbackProvider)

              unless Rack::Utils.secure_compare(attrs[:state], attrs[:expected_state])
                raise ValidationError, "state mismatch"
              end

              token =
                begin
                  provider.exchange_code(
                    code: attrs[:code],
                    redirect_uri: attrs[:redirect_uri],
                    code_verifier: attrs[:code_verifier]
                  )
                rescue StandardError => e
                  ::Rubino::Metrics.counter(:oauth_token_exchanges_total,
                                               provider: provider.id, outcome: "error").increment
                  raise UpstreamError.new("token exchange failed: #{e.class.name}", service: provider.id)
                end

              ::Rubino::Metrics.counter(:oauth_token_exchanges_total,
                                           provider: provider.id, outcome: "ok").increment

              info = provider.fetch_account_info(token[:access_token])

              connection = repository.upsert(
                provider: provider.id,
                account_id: info[:account_id],
                account_email: info[:account_email],
                access_token: token[:access_token],
                refresh_token: token[:refresh_token],
                expires_at: token[:expires_at],
                scopes: token[:scopes],
                metadata: info[:metadata] || {}
              )

              [201, Serializer.call(connection)]
            end

            private

            def repository
              @repository ||= ::Rubino::OAuth::ConnectionRepository.new
            end
          end
        end
      end
    end
  end
end
