# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::Mode::ShowOperation do
  let(:operation) { described_class.new }

  it "returns the current mode plus the list of available modes" do
    status, body = operation.call(make_request)

    expect(status).to eq(200)
    expect(body[:mode]).to eq(:default)
    expect(body[:description]).to be_a(String).and(satisfy { |s| !s.empty? })
    expect(body[:available].map { |m| m[:mode] }).to match_array(%i[default plan yolo])
  end

  it "reflects an active non-default mode" do
    Rubino::Modes.set(:plan)
    _, body = operation.call(make_request)
    expect(body[:mode]).to eq(:plan)
  end
end
