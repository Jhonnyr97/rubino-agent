# frozen_string_literal: true

module Rubino
  # In-process Prometheus-style metrics registry.
  #
  # Counters and histograms only — no gauges (process state is queried lazily
  # by the /v1/health operation). The registry is a process-wide singleton;
  # tests can call Metrics.reset! between examples to start clean.
  #
  #   Metrics.counter(:http_requests_total, method: "GET", status: 200).increment
  #   Metrics.histogram(:http_request_duration_seconds, path: "/v1/runs").observe(0.034)
  #
  # Output is the Prometheus text exposition format (see Renderer), served by
  # API::Operations::MetricsOperation.
  module Metrics
    # Default histogram bucket boundaries (seconds). Tuned for sub-second HTTP
    # request latencies — fine granularity below 100ms, coarser past 1s.
    DEFAULT_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10].freeze

    # Monotonic counter keyed by label set. Thread-safe via internal mutex.
    class Counter
      attr_reader :name, :help

      def initialize(name, help)
        @name = name
        @help = help
        @values = Hash.new(0)
        @mutex = Mutex.new
      end

      # Add `by` to the counter for the given label set (default 1).
      def increment(by: 1, **labels)
        @mutex.synchronize { @values[labels] += by }
      end

      def each(&)
        @mutex.synchronize { @values.dup }.each(&)
      end

      def type = :counter
    end

    # Bucketed distribution keyed by label set. Buckets are CUMULATIVE per
    # Prometheus convention: each observation increments every bucket whose
    # `le >= value`, plus the implicit `+Inf` bucket. Thread-safe.
    class Histogram
      attr_reader :name, :help, :buckets

      def initialize(name, help, buckets: DEFAULT_BUCKETS)
        @name = name
        @help = help
        @buckets = buckets
        @observations = Hash.new { |h, k| h[k] = { counts: Hash.new(0), sum: 0.0, count: 0 } }
        @mutex = Mutex.new
      end

      # Record one observation. Increments every bucket with `le >= value`,
      # the `+Inf` bucket, the `_sum`, and the `_count`.
      def observe(value, **labels)
        @mutex.synchronize do
          obs = @observations[labels]
          @buckets.each { |b| obs[:counts][b] += 1 if value <= b }
          obs[:counts]["+Inf"] += 1
          obs[:sum] += value
          obs[:count] += 1
        end
      end

      def each(&)
        @mutex.synchronize { @observations.dup }.each(&)
      end

      def type = :histogram
    end

    class << self
      # Fetch (or lazily create) the named Counter and bind `labels` for use via Proxy.
      def counter(name, **labels)
        registry[name] ||= Counter.new(name, descriptions.fetch(name, name.to_s))
        Proxy.new(registry[name], labels)
      end

      # Fetch (or lazily create) the named Histogram and bind `labels` for use via Proxy.
      def histogram(name, **labels)
        registry[name] ||= Histogram.new(name, descriptions.fetch(name, name.to_s))
        Proxy.new(registry[name], labels)
      end

      # Set the HELP text for `name`; applied when the metric is first created.
      def describe(name, help)
        descriptions[name] = help
      end

      # Yield each registered metric (Counter or Histogram).
      def each(&) = registry.each_value(&)

      # Drop all registered metrics. Intended for tests.
      def reset!
        @registry = nil
      end

      # Serialize the full registry to Prometheus text exposition format.
      def render
        Renderer.call(registry.values)
      end

      private

      def registry
        @registry ||= {}
      end

      def descriptions
        @descriptions ||= {}
      end
    end

    # Thin wrapper binding a metric to a pre-built label set so call sites
    # read cleanly:
    #   Metrics.counter(:foo, label: "x").increment
    class Proxy
      def initialize(metric, labels)
        @metric = metric
        @labels = labels
      end

      def increment(by: 1)
        @metric.increment(by: by, **@labels)
      end

      def observe(value)
        @metric.observe(value, **@labels)
      end
    end

    # Serializes metrics to Prometheus text exposition format:
    #   # HELP name help text
    #   # TYPE name counter|histogram
    #   name{label="value",...} value
    # Label values are escaped for `"`, `\`, and newline.
    module Renderer
      def self.call(metrics)
        metrics.flat_map { |m| render_metric(m) }.join("\n") + "\n"
      end

      def self.render_metric(metric)
        lines = ["# HELP #{metric.name} #{metric.help}", "# TYPE #{metric.name} #{metric.type}"]
        case metric.type
        when :counter
          metric.each { |labels, value| lines << "#{metric.name}#{format_labels(labels)} #{value}" }
        when :histogram
          metric.each do |labels, data|
            data[:counts].each { |bucket, count| lines << "#{metric.name}_bucket#{format_labels(labels.merge(le: bucket.to_s))} #{count}" }
            lines << "#{metric.name}_sum#{format_labels(labels)} #{data[:sum]}"
            lines << "#{metric.name}_count#{format_labels(labels)} #{data[:count]}"
          end
        end
        lines
      end

      def self.format_labels(labels)
        return "" if labels.empty?

        pairs = labels.map { |k, v| %(#{k}="#{escape(v)}") }.join(",")
        "{#{pairs}}"
      end

      def self.escape(value)
        value.to_s.gsub("\\", '\\\\').gsub('"', '\\"').gsub("\n", '\n')
      end
    end
  end
end
