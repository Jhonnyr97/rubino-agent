# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Rubino::API::Middleware::ErrorHandler do
  let(:logger) { instance_double(Rubino::Logger, error: nil) }

  def middleware_for(error_class, *args)
    error = args.empty? ? error_class.new : error_class.new(*args)
    app = ->(_env) { raise error }
    described_class.new(app, logger: logger)
  end

  def call(mw)
    mw.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/v1/x")
  end

  it "maps NotFoundError to 404" do
    status, headers, body = call(middleware_for(Rubino::NotFoundError, "session", "abc"))
    expect(status).to eq(404)
    expect(headers["content-type"]).to eq("application/json")
    payload = JSON.parse(body.first)
    expect(payload).to match("error" => { "code" => "not_found", "message" => /session not found: abc/ })
  end

  it "maps ValidationError to 422 with details" do
    error = Rubino::ValidationError.new("bad", details: { field: "missing" })
    status, _, body = described_class.new(->(_e) { raise error }, logger: logger)
                                     .call("REQUEST_METHOD" => "POST", "PATH_INFO" => "/v1/x")
    expect(status).to eq(422)
    payload = JSON.parse(body.first)
    expect(payload["error"]["code"]).to eq("validation")
    expect(payload["error"]["details"]).to eq("field" => "missing")
  end

  it "maps UnauthorizedError to 401" do
    status, = call(middleware_for(Rubino::UnauthorizedError))
    expect(status).to eq(401)
  end

  it "maps ConflictError to 409" do
    status, = call(middleware_for(Rubino::ConflictError))
    expect(status).to eq(409)
  end

  it "maps UpstreamError to 502" do
    error = Rubino::UpstreamError.new("timeout", service: "openai")
    status, _, body = described_class.new(->(_e) { raise error }, logger: logger)
                                     .call("REQUEST_METHOD" => "POST", "PATH_INFO" => "/v1/x")
    expect(status).to eq(502)
    payload = JSON.parse(body.first)
    expect(payload["error"]["code"]).to eq("upstream")
    expect(payload["error"]["message"]).to eq("openai: timeout")
  end

  it "preserves UpstreamError messages raised idiomatically (raise Class, 'msg')" do
    app = ->(_e) { raise Rubino::UpstreamError, "boom" }
    status, _, body = described_class.new(app, logger: logger)
                                     .call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/v1/x")
    expect(status).to eq(502)
    expect(JSON.parse(body.first)["error"]["message"]).to eq("boom")
  end

  it "maps unhandled errors to 500 and logs the backtrace" do
    expect(logger).to receive(:error).with(hash_including(event: "api.error.unhandled"))
    status, _, body = call(middleware_for(StandardError, "boom"))
    expect(status).to eq(500)
    expect(JSON.parse(body.first)["error"]).to match("code" => "internal_error", "message" => "internal server error")
  end
end
