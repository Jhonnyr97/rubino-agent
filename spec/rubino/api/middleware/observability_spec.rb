# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Middleware::Observability do
  before { Rubino::Metrics.reset! }
  after  { Rubino::Metrics.reset! }

  let(:logger) { instance_double(Rubino::Logger, info: nil) }
  let(:app) { ->(env) { [201, {}, ["body"]] } }
  let(:middleware) { described_class.new(app, logger: logger) }

  it "records counter + histogram + emits an api.request log line" do
    env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/v1/sessions", "rubino.route" => "/v1/sessions" }
    expect(logger).to receive(:info).with(
      hash_including(event: "api.request", method: "POST", path: "/v1/sessions", status: 201)
    )

    status, _, _ = middleware.call(env)
    expect(status).to eq(201)

    rendered = Rubino::Metrics.render
    expect(rendered).to include('http_requests_total{method="POST",path="/v1/sessions",status="201"} 1')
    expect(rendered).to include('http_request_duration_seconds_count{method="POST",path="/v1/sessions"} 1')
  end

  it "records status=500 when downstream raises and re-raises" do
    app = ->(_env) { raise RuntimeError, "boom" }
    middleware = described_class.new(app, logger: logger)
    env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/v1/health" }

    expect { middleware.call(env) }.to raise_error(RuntimeError, "boom")
    expect(Rubino::Metrics.render).to include('status="500"')
  end

  it "falls back to PATH_INFO when the router did not set rubino.route" do
    env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/v1/unknown" }
    allow(logger).to receive(:info)
    middleware.call(env)
    expect(Rubino::Metrics.render).to include('path="/v1/unknown"')
  end
end
