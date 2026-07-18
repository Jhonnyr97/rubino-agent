# frozen_string_literal: true

require "json"

module Rubino
  # Opt-in OpenTelemetry tracing (config `otel:`, default OFF).
  #
  # When enabled — and the OPTIONAL `opentelemetry-sdk` +
  # `opentelemetry-exporter-otlp` gems are installed — rubino exports spans over
  # OTLP http/protobuf (the only transport the Ruby OTel SDK ships as stable)
  # following the OTel GenAI semantic conventions:
  #
  #   invoke_agent <agent>   one span per turn        (Interaction::Lifecycle)
  #   chat <model>           one span per model call  (Agent::ModelCallRunner)
  #   execute_tool <tool>    one span per tool call   (Agent::ToolExecutor)
  #
  # A subagent turn runs through the same Lifecycle, so its `invoke_agent` span
  # nests under the parent's `execute_tool task` span automatically (foreground
  # delegation; a background subagent thread starts its own trace — OTel context
  # is thread-local).
  #
  # Design rules, in order of importance:
  #   * PRIVACY: message/tool text is NEVER exported by default. Only the
  #     `otel.capture_content` config key (or the standard
  #     OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true env var, the
  #     GenAI-semconv opt-in) adds `gen_ai.input.messages`-style attributes —
  #     and even then payloads pass Logger.redact and are truncated. Everything
  #     exported unconditionally is counts, ids, model names and durations.
  #   * ZERO-COST WHEN OFF: `span` yields a no-op NULL_SPAN without touching
  #     the OTel gems, so a default install pays one memoized boolean check.
  #   * FAIL-OPEN: a missing gem or a broken exporter config logs one warning
  #     and disables telemetry — it can never take down a turn.
  module Telemetry
    # Truncation cap for opt-in content attributes. Keeps a pathological
    # payload (a giant pasted file in a message) from blowing up the span
    # export; generous enough to keep whole ordinary conversations readable.
    CONTENT_MAX_CHARS = 16_000

    # No-op stand-in yielded by .span whenever telemetry is off, so call sites
    # write `span.set_attribute(...)` unconditionally — no nil-checks, no
    # dual code paths. Mirrors the subset of the OTel span API rubino uses.
    class NullSpan
      def set_attribute(_key, _value); end
      def add_attributes(_attributes); end
      def add_event(_name, **_kwargs); end
      def record_exception(_exception); end
      def status=(_status); end
    end

    NULL_SPAN = NullSpan.new.freeze

    class << self
      # Opens a span named +name+ around the block and yields it (a real OTel
      # span when enabled, NULL_SPAN otherwise). Returns the block's value.
      # When enabled, an exception unwinding through the block is recorded on
      # the span with error status and re-raised — the OTel `in_span` contract.
      def span(name, attributes: {}, kind: :internal, &block)
        return block.call(NULL_SPAN) unless enabled?

        tracer.in_span(name, attributes: attributes, kind: kind, &block)
      end

      # Memoized tri-state boot: nil = not yet decided, then true/false for the
      # process lifetime. Config is read once — flipping otel.enabled needs a
      # restart, which keeps every hot call site at one boolean check.
      def enabled?
        @enabled = boot! if @enabled.nil?
        @enabled
      end

      # The GenAI-semconv content-capture opt-in (see the module doc's privacy
      # rule). False whenever telemetry itself is off.
      def capture_content?
        return false unless enabled?

        Rubino.configuration.dig("otel", "capture_content") == true ||
          ENV["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"] == "true"
      end

      # Serializes an opt-in content payload for a span attribute: redacted
      # (Logger.redact masks token/secret-shaped keys at any depth), JSON-encoded
      # and truncated to CONTENT_MAX_CHARS. Callers gate on capture_content?.
      def content(value)
        JSON.generate(Logger.redact(value))[0, CONTENT_MAX_CHARS]
      rescue StandardError
        value.to_s[0, CONTENT_MAX_CHARS]
      end

      # Stamps the GenAI response/usage attributes shared by every LLM call
      # site — the main loop's `chat` span (ModelCallRunner) and the auxiliary
      # tasks' (AuxiliaryClient) — onto +span+. One implementation so the two
      # spans stay attribute-compatible. Accepts anything response-shaped
      # (AdapterResponse); silently skips objects without #usage.
      def record_llm_response(span, response)
        return unless response.respond_to?(:usage)

        usage = response.usage
        span.set_attribute("gen_ai.response.model", response.model_id.to_s) if response.model_id
        span.set_attribute("gen_ai.response.finish_reasons", [response.stop_reason.to_s]) if response.stop_reason
        span.set_attribute("gen_ai.usage.input_tokens", usage[:input_tokens].to_i)
        span.set_attribute("gen_ai.usage.output_tokens", usage[:output_tokens].to_i)
        span.set_attribute("gen_ai.usage.cache_read.input_tokens", usage[:cache_read_input_tokens].to_i)
        span.set_attribute("gen_ai.usage.cache_creation.input_tokens", usage[:cache_creation_input_tokens].to_i)
        span.set_attribute("gen_ai.output.messages", content(response.content)) if capture_content?
      end

      # Flushes and shuts down the exporter (registered at_exit by boot!, so
      # batched spans survive process exit). Safe to call when never booted.
      def shutdown
        @tracer_provider&.shutdown
        nil
      rescue StandardError
        nil
      end

      # Drops all memoized state so the next enabled? re-boots (specs).
      def reset!
        @enabled = nil
        @tracer = nil
        @tracer_provider = nil
      end

      private

      def tracer
        @tracer ||= OpenTelemetry.tracer_provider.tracer("rubino-agent", Rubino::VERSION)
      end

      # One-shot SDK boot. Returns the enabled verdict: false when the config
      # is off, the gems are absent (with an actionable install hint, matching
      # the optional document-converter gems) or the exporter refuses its
      # config. Never raises — telemetry must not take down the agent.
      def boot!
        return false unless Rubino.configuration.dig("otel", "enabled") == true

        require "opentelemetry/sdk"
        require "opentelemetry-exporter-otlp"
        install_sdk!
        at_exit { shutdown }
        true
      rescue LoadError
        Rubino.logger.warn(
          event: "telemetry.gems_missing",
          hint: "otel.enabled is true but the OpenTelemetry gems are not installed — " \
                "run: gem install opentelemetry-sdk opentelemetry-exporter-otlp"
        )
        false
      rescue StandardError => e
        Rubino.logger.warn(event: "telemetry.boot_failed", error: e.message)
        false
      end

      # Builds a dedicated TracerProvider (batched OTLP export) and installs it
      # as the process-global provider. A dedicated provider — rather than
      # OpenTelemetry::SDK.configure — keeps the setup explicit: exactly one
      # exporter, driven by rubino's config, no env-driven auto-configuration
      # surprises (the standard OTEL_EXPORTER_OTLP_* vars still reach the
      # exporter itself as its own defaults).
      def install_sdk!
        exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(**exporter_options)
        @tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new(resource: resource)
        @tracer_provider.add_span_processor(
          OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter)
        )
        OpenTelemetry.tracer_provider = @tracer_provider
      end

      def resource
        attrs = { "service.name" => "rubino-agent", "service.version" => Rubino::VERSION }
        environment = Rubino.configuration.dig("otel", "environment")
        attrs["deployment.environment.name"] = environment.to_s if environment
        extra = Rubino.configuration.dig("otel", "resource_attributes")
        extra.each { |k, v| attrs[k.to_s] = v.to_s } if extra.is_a?(Hash)
        OpenTelemetry::SDK::Resources::Resource.default.merge(
          OpenTelemetry::SDK::Resources::Resource.create(attrs)
        )
      end

      # Only non-nil config reaches the exporter, so an unset key falls back to
      # the exporter's own defaults (OTEL_EXPORTER_OTLP_* env vars, then
      # http://localhost:4318/v1/traces).
      def exporter_options
        options = {}
        endpoint = Rubino.configuration.dig("otel", "endpoint")
        options[:endpoint] = normalize_endpoint(endpoint) if endpoint
        headers = Rubino.configuration.dig("otel", "headers")
        if headers.is_a?(Hash) && headers.any?
          options[:headers] = headers.transform_keys(&:to_s).transform_values(&:to_s)
        end
        options
      end

      # The Ruby OTLP/HTTP exporter takes the FULL per-signal URL, but people
      # configure the collector BASE ("http://localhost:4318") everywhere else —
      # accept both by appending the standard traces path when it is missing.
      def normalize_endpoint(endpoint)
        base = endpoint.to_s.chomp("/")
        base.end_with?("/v1/traces") ? base : "#{base}/v1/traces"
      end
    end
  end
end
