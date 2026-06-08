# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module OAuth
        module Connections
          # DELETE /v1/oauth/connections/:id
          # Removes a stored OAuth connection (encrypted tokens included) and
          # asks the provider to revoke the underlying token, so a DB dump +
          # encryption-key compromise no longer yields indefinite provider-side
          # access.
          #
          # Provider revoke is best-effort: a failure (network, 4xx) is logged
          # and the local row is still destroyed — leaving a stale local row is
          # strictly worse than missing the revoke, since the user thinks the
          # connection is gone and we'd keep using the encrypted tokens.
          #
          # @return [[Integer, nil]] 204 No Content.
          # @raise [Rubino::NotFoundError] when the connection does not exist.
          class DisconnectOperation
            def self.call(request)
              new.call(request)
            end

            # Accepts an alternate repository / registry / logger for tests.
            def initialize(repository: nil, registry: ::Rubino::OAuth::Registry, logger: nil)
              @repository = repository
              @registry = registry
              @logger = logger
            end

            def call(request)
              id = request.params.fetch("id")
              connection = repository.find(id)
              raise NotFoundError.new("oauth_connection", id) unless connection

              revoke_remote(connection)
              repository.destroy!(id)
              [204, nil]
            end

            private

            def revoke_remote(connection)
              provider = @registry.fetch_or_nil(connection[:provider])
              return unless provider&.respond_to?(:revoke)

              # Prefer refresh_token (Google revokes the whole grant) and fall
              # back to access_token (GitHub only knows about user tokens).
              token = connection[:refresh_token] || connection[:access_token]
              return unless token && !token.empty?

              provider.revoke(token)
            rescue StandardError => e
              logger.warn(
                event: "oauth.disconnect.revoke_failed",
                provider: connection[:provider],
                connection_id: connection[:id],
                error_class: e.class.name,
                error_message: e.message
              )
            end

            def repository
              @repository ||= ::Rubino::OAuth::ConnectionRepository.new
            end

            def logger
              @logger ||= ::Rubino.logger
            end
          end
        end
      end
    end
  end
end
