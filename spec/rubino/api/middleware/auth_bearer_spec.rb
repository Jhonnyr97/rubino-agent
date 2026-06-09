# frozen_string_literal: true

require "spec_helper"
require "json"

# Bearer-scheme enforcement. The previous implementation used String#sub which
# silently accepted raw tokens (no scheme) because #sub returns the original
# string when the pattern doesn't match. These specs lock down the RFC 6750
# requirement that the scheme literal "Bearer" must be present.
RSpec.describe Rubino::API::Middleware::Auth, "bearer scheme enforcement" do
  let(:downstream) { ->(_env) { [200, {}, ["ok"]] } }
  let(:api_key) { "s3cret-token" }
  let(:auth) { described_class.new(downstream, api_key: api_key) }
  let(:logger) { instance_double(Rubino::Logger, error: nil) }
  # Wrap Auth in ErrorHandler so rejected requests surface as a real 401 with
  # the canonical { error: { code, message } } envelope rather than a bare raise.
  let(:stack) { Rubino::API::Middleware::ErrorHandler.new(auth, logger: logger) }

  def env(headers: {}, path: "/v1/sessions", method: "GET")
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path
    }.merge(headers.transform_keys { |k| "HTTP_#{k.upcase.tr("-", "_")}" })
  end

  def parse(body)
    JSON.parse(body.first)
  end

  it "rejects requests with no Authorization header" do
    status, _, body = stack.call(env)
    expect(status).to eq(401)
    expect(parse(body)).to match("error" => { "code" => "unauthorized", "message" => /missing/i })
  end

  it "rejects a raw token without the Bearer scheme" do
    # This is the original bug: String#sub returned the header unchanged, so
    # the raw api_key matched itself in secure_compare and auth passed.
    status, _, body = stack.call(env(headers: { "Authorization" => api_key }))
    expect(status).to eq(401)
    expect(parse(body)["error"]["code"]).to eq("unauthorized")
  end

  it "rejects a non-Bearer scheme (Basic)" do
    status, = stack.call(env(headers: { "Authorization" => "Basic #{api_key}" }))
    expect(status).to eq(401)
  end

  it "rejects a Token-prefixed credential" do
    status, = stack.call(env(headers: { "Authorization" => "Token #{api_key}" }))
    expect(status).to eq(401)
  end

  it "rejects an empty token after Bearer" do
    status, _, body = stack.call(env(headers: { "Authorization" => "Bearer " }))
    expect(status).to eq(401)
    expect(parse(body)["error"]["message"]).to match(/missing|empty/i)
  end

  it "rejects Bearer with no trailing space and no token" do
    status, = stack.call(env(headers: { "Authorization" => "Bearer" }))
    expect(status).to eq(401)
  end

  it "accepts a correct Bearer credential" do
    status, _, body = stack.call(env(headers: { "Authorization" => "Bearer #{api_key}" }))
    expect(status).to eq(200)
    expect(body).to eq(["ok"])
  end

  it "accepts case-insensitive scheme per RFC 6750" do
    status, = stack.call(env(headers: { "Authorization" => "bearer #{api_key}" }))
    expect(status).to eq(200)
    status, = stack.call(env(headers: { "Authorization" => "BEARER #{api_key}" }))
    expect(status).to eq(200)
  end

  it "uses Rack::Utils.secure_compare for constant-time token comparison" do
    expect(Rack::Utils).to receive(:secure_compare).with(api_key, api_key).and_call_original
    status, = stack.call(env(headers: { "Authorization" => "Bearer #{api_key}" }))
    expect(status).to eq(200)
  end

  it "does not invoke secure_compare when the scheme is missing (fail fast)" do
    expect(Rack::Utils).not_to receive(:secure_compare)
    stack.call(env(headers: { "Authorization" => api_key }))
  end
end
