# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::Metrics do
  before { described_class.reset! }
  after  { described_class.reset! }

  it "registers and increments counters by label set" do
    described_class.counter(:http_requests_total, method: "GET", path: "/x", status: 200).increment
    described_class.counter(:http_requests_total, method: "GET", path: "/x", status: 200).increment
    described_class.counter(:http_requests_total, method: "GET", path: "/y", status: 404).increment

    output = described_class.render
    expect(output).to include("# TYPE http_requests_total counter")
    expect(output).to include('http_requests_total{method="GET",path="/x",status="200"} 2')
    expect(output).to include('http_requests_total{method="GET",path="/y",status="404"} 1')
  end

  it "observes histograms into buckets + sum + count" do
    h = described_class.histogram(:http_request_duration_seconds, path: "/v1/runs")
    h.observe(0.004)
    h.observe(0.02)
    h.observe(0.4)

    output = described_class.render
    expect(output).to include("# TYPE http_request_duration_seconds histogram")
    expect(output).to include('http_request_duration_seconds_count{path="/v1/runs"} 3')
    expect(output).to match(/http_request_duration_seconds_bucket\{.*le="0.005".*\} 1/)
    expect(output).to match(/http_request_duration_seconds_bucket\{.*le="0.5".*\} 3/)
  end

  it "stores help text from .describe" do
    described_class.describe(:my_counter, "Test counter description.")
    described_class.counter(:my_counter).increment
    expect(described_class.render).to include("# HELP my_counter Test counter description.")
  end

  it "escapes quotes in label values" do
    described_class.counter(:weird, path: 'a"b').increment
    expect(described_class.render).to include('path="a\\"b"')
  end
end
