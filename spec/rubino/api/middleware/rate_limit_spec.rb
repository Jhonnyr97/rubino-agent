# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Rubino::API::Middleware::RateLimit do
  let(:downstream) { ->(_env) { [200, {}, ["ok"]] } }
  # Hand-cranked clock so the bucket-refill assertions don't depend on wall time.
  let(:clock_time) { [0.0] }
  let(:clock) { -> { clock_time[0] } }
  let(:middleware) { described_class.new(downstream, clock: clock) }

  def env(path: "/v1/health", remote_ip: "10.0.0.1", token: nil)
    h = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => path,
      "REMOTE_ADDR" => remote_ip
    }
    h["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    h
  end

  def parse(body)
    JSON.parse(body.first)
  end

  def configure_limits(unauth: 2, auth: 4, enabled: true)
    raw = Rubino.configuration.instance_variable_get(:@raw)
    raw["api"] ||= {}
    raw["api"]["rate_limit_enabled"] = enabled
    raw["api"]["rate_limit_unauth_per_minute"] = unauth
    raw["api"]["rate_limit_auth_per_minute"] = auth
  end

  before { configure_limits }

  it "lets unauthenticated requests through until the per-IP bucket is exhausted" do
    2.times do
      status, = middleware.call(env)
      expect(status).to eq(200)
    end
  end

  it "returns 429 with retry_after_seconds details and Retry-After header when the unauth bucket is exceeded" do
    2.times { middleware.call(env) }

    status, headers, body = middleware.call(env)
    expect(status).to eq(429)
    expect(headers["content-type"]).to eq("application/json")
    expect(headers["retry-after"]).to match(/\A\d+\z/)

    envelope = parse(body)
    expect(envelope["error"]["code"]).to eq("rate_limited")
    expect(envelope["error"]["message"]).to match(/rate limit/i)
    expect(envelope["error"]["details"]["retry_after_seconds"]).to be > 0
    expect(headers["retry-after"].to_i).to eq(envelope["error"]["details"]["retry_after_seconds"])
  end

  it "keeps the auth bucket separate from the unauth bucket" do
    # Exhaust the unauth bucket entirely.
    2.times { middleware.call(env) }
    status, = middleware.call(env)
    expect(status).to eq(429)

    # An authenticated request from the same IP must still be allowed because
    # the bearer-token bucket has not been touched.
    status, = middleware.call(env(path: "/v1/sessions", token: "abc"))
    expect(status).to eq(200)
  end

  it "tracks each bearer token in its own bucket" do
    4.times { middleware.call(env(path: "/v1/sessions", token: "alpha")) }
    status, = middleware.call(env(path: "/v1/sessions", token: "alpha"))
    expect(status).to eq(429)

    # Different token — its own fresh bucket.
    status, = middleware.call(env(path: "/v1/sessions", token: "beta"))
    expect(status).to eq(200)
  end

  it "refills the bucket as time advances and lets the request through once a token is available" do
    2.times { middleware.call(env) }
    status, = middleware.call(env)
    expect(status).to eq(429)

    # Refill rate at unauth=2/min is 1 token / 30s. Advance just past one refill.
    clock_time[0] += 30.1
    status, = middleware.call(env)
    expect(status).to eq(200)
  end

  it "fully refills the bucket after the configured window has passed" do
    2.times { middleware.call(env) }
    expect(middleware.call(env).first).to eq(429)

    clock_time[0] += 60.0
    2.times do
      status, = middleware.call(env)
      expect(status).to eq(200)
    end
    expect(middleware.call(env).first).to eq(429)
  end

  it "is a no-op when rate_limit_enabled is false" do
    configure_limits(unauth: 1, enabled: false)
    5.times do
      status, = middleware.call(env)
      expect(status).to eq(200)
    end
  end

  it "uses the unauth bucket when no Authorization header is present" do
    # Mixed traffic from the same IP: hit the unauth ceiling with no token,
    # then verify a tokened request from the same IP is not penalised.
    2.times { middleware.call(env) }
    expect(middleware.call(env).first).to eq(429)
    expect(middleware.call(env(token: "tok")).first).to eq(200)
  end
end
