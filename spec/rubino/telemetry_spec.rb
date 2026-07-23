# frozen_string_literal: true

require "opentelemetry/sdk"

RSpec.describe Rubino::Telemetry do
  after { described_class.reset! }

  # Boots the module against an in-memory exporter (no OTLP, no network) so
  # specs assert on finished spans. Bypasses boot! — the SDK wiring itself is
  # config-driven glue; what matters here is the span/attribute contract every
  # call site programs against.
  def enable_with_test_tracer
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    described_class.instance_variable_set(:@enabled, true)
    described_class.instance_variable_set(:@tracer, provider.tracer("test"))
    exporter
  end

  describe "disabled (the default)" do
    it "is disabled with the default configuration" do
      allow(Rubino).to receive(:configuration).and_return(test_configuration)
      expect(described_class.enabled?).to be(false)
    end

    it "yields the no-op NULL_SPAN and returns the block value" do
      described_class.instance_variable_set(:@enabled, false)
      yielded = nil
      out = described_class.span("chat x") do |span|
        yielded = span
        span.set_attribute("k", "v") # must not raise
        :value
      end
      expect(out).to be(:value)
      expect(yielded).to be(described_class::NULL_SPAN)
    end

    it "reports capture_content? false even when the config opts in" do
      allow(Rubino).to receive(:configuration)
        .and_return(test_configuration("otel" => { "enabled" => false, "capture_content" => true }))
      expect(described_class.capture_content?).to be(false)
    end
  end

  describe "boot failure paths" do
    it "disables itself with an install hint when the gems are absent" do
      allow(Rubino).to receive(:configuration)
        .and_return(test_configuration("otel" => { "enabled" => true }))
      allow(described_class).to receive(:require).and_raise(LoadError)
      expect(Rubino.logger).to receive(:warn).with(hash_including(event: "telemetry.gems_missing"))
      expect(described_class.enabled?).to be(false)
    end

    it "disables itself (never raises) when the SDK boot blows up" do
      allow(Rubino).to receive(:configuration)
        .and_return(test_configuration("otel" => { "enabled" => true }))
      allow(described_class).to receive(:install_sdk!).and_raise(ArgumentError, "bad endpoint")
      expect(Rubino.logger).to receive(:warn).with(hash_including(event: "telemetry.boot_failed"))
      expect(described_class.enabled?).to be(false)
    end
  end

  # The runtime half of fail-open: a collector that is down after a clean boot
  # must degrade quietly instead of spamming OTel's default ERROR-to-stderr.
  describe "collector-unreachable error handler" do
    around do |example|
      previous = OpenTelemetry.error_handler
      example.run
    ensure
      OpenTelemetry.error_handler = previous
    end

    before do
      allow(Rubino).to receive(:configuration)
        .and_return(test_configuration("otel" => { "enabled" => true, "endpoint" => "http://localhost:4318" }))
      described_class.send(:install_error_handler!)
    end

    it "installs itself as the process-global OpenTelemetry error handler" do
      expect(OpenTelemetry.error_handler).to respond_to(:call)
    end

    # The SDK surfaces a failed batch flush as an ExportError via `exception:`
    # (message "Unable to export N spans"), which is exactly what the user sees
    # spammed when the collector is down — assert on that real shape.
    it "warns ONCE (actionable, with endpoint) then falls to debug on repeat batch-export failures" do
      export_error = OpenTelemetry::SDK::Trace::Export::ExportError.new("Unable to export 2 spans")
      expect(Rubino.logger).to receive(:warn)
        .once.with(hash_including(event: "telemetry.collector_unreachable",
                                  endpoint: "http://localhost:4318/v1/traces"))
      expect(Rubino.logger).to receive(:debug)
        .with(hash_including(event: "telemetry.export_dropped"))

      OpenTelemetry.error_handler.call(exception: export_error)
      OpenTelemetry.error_handler.call(exception: export_error)
    end

    it "also matches the batch-export failure passed via the message kwarg" do
      expect(Rubino.logger).to receive(:warn).with(hash_including(event: "telemetry.collector_unreachable"))
      OpenTelemetry.error_handler.call(message: "Unable to export 3 spans")
    end

    it "treats a transport connection error as unreachable, not an unexpected error" do
      expect(Rubino.logger).to receive(:warn).with(hash_including(event: "telemetry.collector_unreachable"))
      OpenTelemetry.error_handler.call(exception: Errno::ECONNREFUSED.new("Connection refused"))
    end

    it "surfaces a genuinely unexpected OTel error at warn (never silently swallowed)" do
      expect(Rubino.logger).to receive(:warn)
        .with(hash_including(event: "telemetry.otel_error", error: a_string_including("boom")))
      OpenTelemetry.error_handler.call(exception: ArgumentError.new("boom"), message: "unexpected")
    end
  end

  describe ".span (enabled)" do
    it "exports a finished span with name, kind and attributes" do
      exporter = enable_with_test_tracer
      described_class.span("chat gpt-x", kind: :client, attributes: { "gen_ai.request.model" => "gpt-x" }) do |span|
        span.set_attribute("gen_ai.usage.input_tokens", 7)
      end
      expect(exporter.finished_spans.size).to eq(1)
      span = exporter.finished_spans.first
      expect(span.name).to eq("chat gpt-x")
      expect(span.kind).to eq(:client)
      expect(span.attributes).to include("gen_ai.request.model" => "gpt-x", "gen_ai.usage.input_tokens" => 7)
    end

    it "nests spans opened inside the block under the outer span" do
      exporter = enable_with_test_tracer
      described_class.span("invoke_agent rubino") do
        described_class.span("chat gpt-x") { nil }
      end
      inner, outer = exporter.finished_spans
      expect(inner.parent_span_id).to eq(outer.span_id)
    end

    it "records an exception on the span, marks it error, and re-raises" do
      exporter = enable_with_test_tracer
      expect do
        described_class.span("execute_tool shell") { raise Rubino::ToolError, "boom" }
      end.to raise_error(Rubino::ToolError, "boom")
      expect(exporter.finished_spans.size).to eq(1)
      span = exporter.finished_spans.first
      expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
      expect(span.events.map(&:name)).to include("exception")
    end
  end

  describe ".capture_content?" do
    before { described_class.instance_variable_set(:@enabled, true) }

    it "is false by default (privacy gate)" do
      allow(Rubino).to receive(:configuration).and_return(test_configuration)
      expect(described_class.capture_content?).to be(false)
    end

    it "is true when the config opts in" do
      allow(Rubino).to receive(:configuration)
        .and_return(test_configuration("otel" => { "capture_content" => true }))
      expect(described_class.capture_content?).to be(true)
    end

    it "honours the standard GenAI-semconv env var" do
      allow(Rubino).to receive(:configuration).and_return(test_configuration)
      stub_const("ENV", ENV.to_h.merge("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT" => "true"))
      expect(described_class.capture_content?).to be(true)
    end
  end

  describe ".content" do
    it "JSON-encodes and redacts secret-shaped keys at any depth" do
      json = described_class.content([{ role: "user", content: "hi", api_key: "sk-secret" }])
      expect(json).to include('"content":"hi"')
      expect(json).to include(Rubino::Logger::REDACTED)
      expect(json).not_to include("sk-secret")
    end

    it "truncates to CONTENT_MAX_CHARS" do
      out = described_class.content("a" * (described_class::CONTENT_MAX_CHARS * 2))
      expect(out.length).to be <= described_class::CONTENT_MAX_CHARS
    end

    it "degrades to to_s on an unserializable value" do
      unserializable = Object.new.tap { |o| o.define_singleton_method(:to_json) { |*| raise "nope" } }
      expect(described_class.content(unserializable)).to be_a(String)
    end
  end

  describe "endpoint normalization" do
    it "appends the standard traces path to a collector base URL" do
      expect(described_class.send(:normalize_endpoint, "http://localhost:4318")).to eq("http://localhost:4318/v1/traces")
      expect(described_class.send(:normalize_endpoint, "http://c:4318/")).to eq("http://c:4318/v1/traces")
    end

    it "leaves a full traces URL untouched" do
      expect(described_class.send(:normalize_endpoint, "https://c.example/v1/traces")).to eq("https://c.example/v1/traces")
    end
  end
end
