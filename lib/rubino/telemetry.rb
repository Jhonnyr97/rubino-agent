# frozen_string_literal: true

require "json"
require "timeout"

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
  #     and disables telemetry (boot!); a collector that is unreachable at
  #     runtime logs ONE actionable warning then degrades quietly while the SDK
  #     keeps retrying (install_error_handler!). Telemetry can never take down a
  #     turn, and a down collector never spams the log.
  module Telemetry
    # Truncation cap for opt-in content attributes. Keeps a pathological
    # payload (a giant pasted file in a message) from blowing up the span
    # export; generous enough to keep whole ordinary conversations readable.
    CONTENT_MAX_CHARS = 16_000

    # Transport-level failures that mean "the OTLP collector is unreachable"
    # (down, wrong port, dead connection) rather than a bug in rubino. Every
    # Errno::* is a SystemCallError, so that one entry covers ECONNREFUSED /
    # ECONNRESET / EHOSTUNREACH; SocketError covers DNS; Timeout::Error covers
    # Net::Open/ReadTimeout. Routine when a local Grafana/collector is off, so
    # the error handler throttles these instead of logging every retry. See
    # #install_error_handler!.
    EXPORT_CONNECTIVITY_ERRORS = [
      SystemCallError, SocketError, IOError, Timeout::Error
    ].freeze

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
        @collector_unreachable_warned = nil
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
        install_error_handler!
        exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(**exporter_options)
        @tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new(resource: resource)
        @tracer_provider.add_span_processor(
          OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter)
        )
        OpenTelemetry.tracer_provider = @tracer_provider
      end

      # OTel funnels every internal failure — most visibly the
      # BatchSpanProcessor's "Unable to export N spans" when a flush fails —
      # through one process-global handler whose default logs at ERROR to
      # stderr, once per retry. We take it over so a DOWN collector degrades
      # QUIETLY: an unreachable-collector failure surfaces ONE actionable WARN
      # and then falls to debug for the rest of the process, while the SDK keeps
      # buffering and retrying (so spans resume the moment the collector returns).
      # This is the RUNTIME half of the module's fail-open contract — boot!
      # covers missing gems / bad config; this covers a collector that is off, or
      # dies, after a clean boot. Genuinely unexpected OTel errors still surface
      # (one WARN via rubino's logger, never the ERROR-on-stderr spam).
      def install_error_handler!
        OpenTelemetry.error_handler = lambda do |exception: nil, message: nil|
          if collector_unreachable?(exception, message)
            note_collector_unreachable(exception, message)
          else
            Rubino.logger.warn(event: "telemetry.otel_error", error: describe_error(exception, message))
          end
        end
      end

      # True for the "collector is down / unreachable" family: the batch
      # processor reporting a failed export, or a transport-level connection
      # error from the exporter. These are routine when the OTLP endpoint is off
      # and must not spam the log at ERROR. Note the SDK surfaces the failed
      # flush as an ExportError passed via `exception:` (message "Unable to
      # export N spans"), so we match the signature on the exception's message
      # too, not just the `message:` kwarg.
      def collector_unreachable?(exception, message)
        return true if describe_error(exception, message).include?("Unable to export")

        !exception.nil? && EXPORT_CONNECTIVITY_ERRORS.any? { |klass| exception.is_a?(klass) }
      end

      # Log the first unreachable-collector event as a single actionable WARN,
      # then stay quiet (debug) for the rest of the process — a whole session
      # against a down collector yields one line, not one per batch flush.
      def note_collector_unreachable(exception, message)
        if @collector_unreachable_warned
          Rubino.logger.debug(event: "telemetry.export_dropped", error: describe_error(exception, message))
          return
        end

        @collector_unreachable_warned = true
        Rubino.logger.warn(
          event: "telemetry.collector_unreachable",
          endpoint: effective_endpoint,
          hint: "OTLP collector unreachable — spans are being dropped while it is down. " \
                "rubino keeps retrying, so telemetry resumes once it is back; " \
                "start the collector, repoint otel.endpoint, or set otel.enabled=false to silence this."
        )
      end

      def describe_error(exception, message)
        [message, exception&.message].compact.join(": ")
      end

      # The endpoint the exporter is actually targeting, for the unreachable
      # warning: rubino's config if set, otherwise the standard OTLP env vars,
      # otherwise the SDK default. Mirrors exporter_options / normalize_endpoint.
      def effective_endpoint
        configured = Rubino.configuration.dig("otel", "endpoint")
        return normalize_endpoint(configured) if configured

        ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
          ENV["OTEL_EXPORTER_OTLP_ENDPOINT"] ||
          "http://localhost:4318/v1/traces"
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
