# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"

RSpec.describe Rubino::API::Middleware::JsonParser, "body size cap" do
  let(:downstream) { ->(env) { [200, {}, [env["rubino.json"].to_json]] } }
  let(:middleware) { described_class.new(downstream) }

  def env_for(body, content_length: body.bytesize)
    {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/v1/sessions/abc/runs",
      "CONTENT_TYPE" => "application/json",
      "CONTENT_LENGTH" => content_length.to_s,
      "rack.input" => StringIO.new(body)
    }
  end

  def parse_envelope(body)
    JSON.parse(body.first)
  end

  it "rejects with 413 when Content-Length exceeds the limit" do
    huge = (5 * 1024 * 1024) + 1
    payload = { "x" => "y" }.to_json
    status, headers, body = middleware.call(env_for(payload, content_length: huge))

    expect(status).to eq(413)
    expect(headers["content-type"]).to eq("application/json")
    envelope = parse_envelope(body)
    expect(envelope["error"]["code"]).to eq("validation")
    expect(envelope["error"]["message"]).to match(/request body too large.*5242880 bytes/)
    expect(envelope["error"]["details"]).to eq("max_bytes" => 5 * 1024 * 1024)
  end

  it "rejects with 413 when Content-Length lies but the body is actually too large" do
    # Limit it to something tiny via config so we don't have to allocate 5 MiB.
    Rubino.configuration.instance_variable_get(:@raw)["api"] = { "max_body_bytes" => 16 }

    real_body = "a" * 64
    status, _, body = middleware.call(env_for(real_body, content_length: 4)) # lying small

    expect(status).to eq(413)
    expect(parse_envelope(body)["error"]["details"]).to eq("max_bytes" => 16)
  end

  it "passes through and parses the body when within the limit" do
    payload = { "input" => "hi" }.to_json
    status, _, body = middleware.call(env_for(payload))

    expect(status).to eq(200)
    expect(JSON.parse(body.first)).to eq("input" => "hi")
  end

  it "honours the configured api.max_body_bytes to reject smaller bodies" do
    Rubino.configuration.instance_variable_get(:@raw)["api"] = { "max_body_bytes" => 4 }

    payload = { "input" => "hi" }.to_json # well over 4 bytes
    status, _, body = middleware.call(env_for(payload))

    expect(status).to eq(413)
    expect(parse_envelope(body)["error"]["details"]).to eq("max_bytes" => 4)
  end
end
