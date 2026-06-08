# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Rubino::API::Router do
  let(:hello_op) { Class.new { def self.call(req) = { hello: req.params["name"] } } }
  let(:show_op)  { Class.new { def self.call(req) = { id: req.params["id"] } } }
  let(:tuple_op) { Class.new { def self.call(_req) = [201, { created: true }] } }

  subject(:router) do
    described_class.new.tap do |r|
      r.get  "/v1/hello/:name", to: hello_op
      r.get  "/v1/items/:id",   to: show_op
      r.post "/v1/items",       to: tuple_op
    end
  end

  def env(method:, path:)
    { "REQUEST_METHOD" => method, "PATH_INFO" => path, "rubino.json" => {}, "QUERY_STRING" => "" }
  end

  it "routes to the matching operation and captures path params" do
    status, _, body = router.call(env(method: "GET", path: "/v1/hello/world"))
    expect(status).to eq(200)
    expect(JSON.parse(body.first)).to eq("hello" => "world")
  end

  it "coerces [status, body] tuples to a JSON response" do
    status, _, body = router.call(env(method: "POST", path: "/v1/items"))
    expect(status).to eq(201)
    expect(JSON.parse(body.first)).to eq("created" => true)
  end

  it "returns 404 for unknown routes" do
    status, _, body = router.call(env(method: "GET", path: "/v1/nope"))
    expect(status).to eq(404)
    expect(JSON.parse(body.first)["error"]["code"]).to eq("not_found")
  end

  it "distinguishes routes by HTTP method" do
    status, = router.call(env(method: "DELETE", path: "/v1/items/abc"))
    expect(status).to eq(404)
  end
end
