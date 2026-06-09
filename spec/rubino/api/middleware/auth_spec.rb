# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Middleware::Auth do
  let(:downstream) { ->(_env) { [200, {}, ["ok"]] } }
  let(:api_key) { "secret" }
  let(:middleware) { described_class.new(downstream, api_key: api_key) }

  def env(headers: {}, path: "/v1/sessions", method: "GET")
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path
    }.merge(headers.transform_keys { |k| "HTTP_#{k.upcase.tr("-", "_")}" })
  end

  it "passes through with a valid bearer token" do
    status, _, body = middleware.call(env(headers: { "Authorization" => "Bearer #{api_key}" }))
    expect(status).to eq(200)
    expect(body).to eq(["ok"])
  end

  it "is case-insensitive on the Bearer scheme" do
    status, = middleware.call(env(headers: { "Authorization" => "bearer #{api_key}" }))
    expect(status).to eq(200)
  end

  it "raises UnauthorizedError on missing header" do
    expect { middleware.call(env) }.to raise_error(Rubino::UnauthorizedError, /missing/)
  end

  it "raises UnauthorizedError on wrong token" do
    expect { middleware.call(env(headers: { "Authorization" => "Bearer wrong" })) }
      .to raise_error(Rubino::UnauthorizedError, /invalid/)
  end

  it "skips auth for /v1/health" do
    status, = middleware.call(env(path: "/v1/health"))
    expect(status).to eq(200)
  end

  it "skips auth for /v1/metrics" do
    status, = middleware.call(env(path: "/v1/metrics"))
    expect(status).to eq(200)
  end
end
