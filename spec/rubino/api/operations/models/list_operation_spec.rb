# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::Models::ListOperation do
  it "serializes models with id/provider/context_window" do
    fake_models = [
      Struct.new(:id, :provider, :context_window).new("openai/gpt-4o", :openai, 128_000),
      Struct.new(:id, :provider, :context_window).new("anthropic/claude", :anthropic, 200_000)
    ]
    operation = described_class.new(model_source: -> { fake_models })
    status, body = operation.call(make_request)
    expect(status).to eq(200)
    expect(body).to eq([
                         { id: "openai/gpt-4o", provider: "openai", context_window: 128_000 },
                         { id: "anthropic/claude", provider: "anthropic", context_window: 200_000 }
                       ])
  end

  it "tolerates plain hash entries" do
    operation = described_class.new(model_source: -> { [{ id: "x" }] })
    _, body = operation.call(make_request)
    expect(body.first[:id]).to eq("x")
  end
end
