# frozen_string_literal: true

module Rubino
  module Agent
    # The provider/model fallback chain — a faithful port of the reference
    # `_fallback_chain` + `try_activate_fallback`
    # and the per-turn `_restore_primary_runtime`.
    #
    # WHAT IT DOES. The primary backend is index 0; `agent.fallback_models` lists
    # the ordered fallbacks. When the primary keeps failing — invalid/empty
    # responses (eager fallback), rate-limit/overload, or an exhausted
    # retry budget, or empty-after-retries — the runner
    # / recovery ladder calls #activate_next! to rotate to the next backend and
    # rebuild the adapter. At the TOP of each new turn ConversationLoop#run calls
    # #restore_primary! so every turn gets a fresh attempt with the preferred
    # model.
    #
    # DEDUP. An entry that resolves to the CURRENT provider/model/base_url is
    # skipped — falling back to the backend that just failed only loops the
    # failure. We keep advancing past skipped entries in a
    # single #activate_next! call, exactly like the reference recursive
    # `return agent._try_activate_fallback()`.
    #
    # GLOBAL-CONFIG ISOLATION (the heart of this slice).
    # `RubyLLM.configure` is process-global; a naive provider swap would corrupt
    # concurrent sessions on the API/server path. So fallback adapters are built
    # with `isolate_config: true`: each scopes its provider config (base_url /
    # api_key / timeout) into a per-adapter `RubyLLM::Context` and NEVER writes
    # the global. The primary adapter is passed in as-is (it already configured
    # the global at construction, exactly as before), so a single-provider setup
    # — and the no-fallback case — is byte-identical to pre-Slice-7 behaviour.
    #
    # NO-OP WHEN UNCONFIGURED. With an empty `fallback_models` the chain holds
    # only the primary: #activate_next! is always false and #current_adapter is
    # always the primary. Nothing is rebuilt, nothing is mutated.
    class FallbackChain
      # One backend in the chain. provider/model are required to be usable; an
      # entry missing either is treated as invalid and skipped on advance.
      Entry = Struct.new(:provider, :model, :base_url, :api_key, keyword_init: true) do
        def usable?
          !provider.to_s.strip.empty? && !model.to_s.strip.empty?
        end
      end

      # primary_adapter : the already-built primary LLM adapter (index 0). The
      #                   chain never rebuilds it — restore just points back to it.
      # config          : the live Configuration (reads agent.fallback_models and
      #                   the providers.* blocks the fallback entries inherit).
      # adapter_builder : injectable seam for tests; defaults to AdapterFactory.
      def initialize(primary_adapter:, config:, ui: nil, event_bus: nil,
                     tool_executor: nil, cancel_token: nil,
                     adapter_builder: LLM::AdapterFactory)
        @primary         = primary_adapter
        @config          = config
        @ui              = ui
        @event_bus       = event_bus
        @tool_executor   = tool_executor
        @cancel_token    = cancel_token
        @adapter_builder = adapter_builder

        @entries = build_entries
        @index   = 0
        @active  = @primary
      end

      # The adapter the loop/runner should issue calls against right now.
      def current_adapter
        @active
      end

      # True once a fallback has been activated this turn — lets callers emit the
      # "switched to fallback" status only when something actually changed.
      def active?
        @index.positive?
      end

      # Advance to the next usable, non-duplicate fallback and rebuild the
      # adapter. Returns true if it actually switched, false when the chain is
      # exhausted (or empty). Mirrors try_activate_fallback (helpers.py:1020):
      # skip invalid entries and entries that resolve to the current backend,
      # advancing past them within this one call.
      def activate_next!
        loop do
          return false if @index >= @entries.size

          entry = @entries[@index]
          @index += 1

          next unless entry.usable?
          next if duplicate_of_current?(entry)

          @active = build_adapter(entry)
          return true
        end
      end

      # Reset to the primary at the top of each turn. No-op cost when
      # we never left the primary; rebuilds nothing (the primary adapter is the
      # one handed in at construction).
      def restore_primary!
        @index  = 0
        @active = @primary
      end

      private

      # The fallback entries (NOT including the implicit primary at index 0).
      def build_entries
        Array(@config.dig("agent", "fallback_models")).filter_map do |raw|
          next unless raw.is_a?(Hash)

          Entry.new(
            provider: fetch(raw, "provider"),
            model:    fetch(raw, "model"),
            base_url: fetch(raw, "base_url"),
            api_key:  fetch(raw, "api_key")
          )
        end
      end

      def fetch(hash, key)
        value = hash[key] || hash[key.to_sym]
        value.to_s.strip.empty? ? nil : value.to_s
      end

      # Skip an entry whose RESOLVED provider+model (or base_url+model) matches the
      # active adapter — falling back to the same backend just loops the failure.
      def duplicate_of_current?(entry)
        resolved = LLM::ProviderResolver.resolve(entry.model, explicit_provider: entry.provider)
        cur_provider = @active.provider.to_s.strip.downcase
        cur_model    = @active.model_id.to_s.strip

        if resolved.to_s.strip.downcase == cur_provider && entry.model.to_s.strip == cur_model
          return true
        end

        entry_base = normalize_url(entry.base_url)
        cur_base   = normalize_url(current_base_url)
        !entry_base.empty? && !cur_base.empty? &&
          entry_base == cur_base && entry.model.to_s.strip == cur_model
      end

      # The base_url the active adapter is pointed at (its provider's config
      # base_url), for the dedup comparison.
      def current_base_url
        @config.provider_config(@active.provider)["base_url"]
      end

      def normalize_url(url)
        url.to_s.strip.sub(%r{/+\z}, "").downcase
      end

      # Rebuild the adapter for a fallback entry. The entry's base_url/api_key
      # override the providers.<name> block for THIS adapter only; everything is
      # scoped into a per-call RubyLLM::Context via isolate_config: true so the
      # process-global RubyLLM.configure is never mutated.
      def build_adapter(entry)
        @adapter_builder.build(
          model_id:       entry.model,
          provider:       entry.provider,
          config:         config_for(entry),
          ui:             @ui,
          event_bus:      @event_bus,
          tool_executor:  @tool_executor,
          cancel_token:   @cancel_token,
          isolate_config: true
        )
      end

      # A per-entry Configuration whose providers.<provider> block carries the
      # entry's base_url/api_key overrides, leaving the shared config untouched
      # (deep-dup of the provider section only — nothing else is copied or
      # mutated). The adapter reads base_url/api_key from here.
      def config_for(entry)
        overrides = {}
        overrides["base_url"] = entry.base_url if entry.base_url
        overrides["api_key"]  = entry.api_key  if entry.api_key
        return @config if overrides.empty?

        raw      = deep_dup(@config.raw)
        provider = entry.provider.to_s
        raw["providers"] ||= {}
        raw["providers"][provider] = (raw["providers"][provider] || {}).merge(overrides)
        Config::Configuration.new(raw: raw)
      end

      def deep_dup(obj)
        case obj
        when Hash  then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
        when Array then obj.map { |v| deep_dup(v) }
        else obj
        end
      end
    end
  end
end
