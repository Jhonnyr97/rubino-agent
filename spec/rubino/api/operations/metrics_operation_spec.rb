# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::MetricsOperation do
  before { Rubino::Metrics.reset! }
  after  { Rubino::Metrics.reset! }

  it "returns the prometheus text payload with the right content-type" do
    Rubino::Metrics.counter(:http_requests_total, method: "GET", status: 200).increment

    status, headers, body = described_class.call(make_request)
    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("text/plain; version=0.0.4")
    expect(body.first).to include('http_requests_total{method="GET",status="200"} 1')
  end
end
