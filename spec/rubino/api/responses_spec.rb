# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Rubino::API::Responses do
  describe ".coerce" do
    it "wraps a Hash as a 200 JSON triple" do
      status, headers, body = described_class.coerce(ok: true)
      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/json")
      expect(JSON.parse(body.first)).to eq("ok" => true)
    end

    it "encodes a 2-tuple as <status>+JSON body" do
      status, _, body = described_class.coerce([201, { created: 1 }])
      expect(status).to eq(201)
      expect(JSON.parse(body.first)).to eq("created" => 1)
    end

    it "passes a 3-tuple Rack triple through unchanged" do
      headers = { "content-type" => "text/plain" }
      result = described_class.coerce([200, headers, ["hi"]])
      expect(result).to eq([200, headers, ["hi"]])
    end

    # RFC 7231 §6.3.5: 204 responses MUST NOT include a message body. The
    # previous coerce path turned `[204, nil]` into the JSON literal `null\n`,
    # which broke strict HTTP/2 clients and leaked "nil-shaped" bodies to API
    # consumers.
    context "with a 204 status" do
      it "emits an empty string body when the operation returned nil" do
        status, _headers, body = described_class.coerce([204, nil])
        expect(status).to eq(204)
        expect(body).to eq([""])
      end

      it "emits an empty string body even when the operation returned a payload" do
        status, _headers, body = described_class.coerce([204, { ignored: true }])
        expect(status).to eq(204)
        expect(body).to eq([""])
      end

      it "does not advertise application/json for the empty body" do
        _status, headers, _body = described_class.coerce([204, nil])
        expect(headers).to eq({})
      end
    end
  end
end
