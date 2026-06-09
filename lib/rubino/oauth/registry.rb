# frozen_string_literal: true

module Rubino
  module OAuth
    # Process-wide registry of configured OAuth providers. Mutex-protected so
    # +register+ / +reset!+ are safe under concurrent boot or reload.
    #
    # Hydrated from +oauth.providers.*+ in Rubino.configuration; only ids
    # listed in {BUILTINS} are considered, and any section missing both
    # +client_id+ and +client_secret+ is silently skipped so a partial config
    # never raises at boot (it just hides the provider from
    # +/v1/oauth/providers+).
    module Registry
      BUILTINS = {
        github: "Rubino::OAuth::Provider::Github",
        google: "Rubino::OAuth::Provider::Google"
      }.freeze

      class << self
        def register(id, instance)
          mutex.synchronize { providers[id.to_sym] = instance }
          instance
        end

        # @param id [String, Symbol]
        # @return [Provider]
        # @raise [Rubino::NotFoundError] when no provider is registered for +id+
        def fetch(id)
          providers[id.to_sym] or raise NotFoundError.new("oauth_provider", id)
        end

        def fetch_or_nil(id)
          providers[id.to_sym]
        end

        def all
          providers.values
        end

        def ids
          providers.keys
        end

        def reset!
          mutex.synchronize { providers.clear }
        end

        # Hydrate from the loaded Rubino configuration. Reads oauth.providers.*
        # sections; for each id matching a BUILTIN, instantiates and registers
        # using its declared client_id/client_secret/scopes. Replaces any
        # previously registered providers ({#reset!} runs first).
        #
        # @param configuration [#dig] anything responding to +dig("oauth", "providers")+
        # @return [Array<Provider>] providers registered by this call
        def load_from_config!(configuration = Rubino.configuration)
          reset!
          oauth_cfg = configuration.dig("oauth", "providers") || {}
          oauth_cfg.each do |id, cfg|
            klass_name = BUILTINS[id.to_sym]
            next unless klass_name
            next unless cfg["client_id"] && cfg["client_secret"]

            klass = Object.const_get(klass_name)
            register(id, klass.new(
                           client_id: cfg["client_id"],
                           client_secret: cfg["client_secret"],
                           scopes: cfg["scopes"],
                           metadata: cfg.reject { |k, _| %w[client_id client_secret scopes].include?(k) }
                         ))
          end
          all
        end

        private

        def providers
          @providers ||= {}
        end

        def mutex
          @mutex ||= Mutex.new
        end
      end
    end
  end
end
