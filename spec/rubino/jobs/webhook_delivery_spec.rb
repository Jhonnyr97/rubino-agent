# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Rubino::Jobs::WebhookDelivery do
  let(:url) { "https://example.test/hook" }
  let(:logger) { instance_double(Rubino::Logger, info: nil, error: nil, warn: nil) }

  it "POSTs JSON to the configured URL and returns true on success" do
    stub_request(:post, url).with(headers: { "Content-Type" => "application/json" })
                            .to_return(status: 200, body: "ok")
    delivery = described_class.new(url: url, logger: logger)
    expect(delivery.deliver({ run_id: "r1", status: "completed" })).to be(true)
    expect(WebMock).to have_requested(:post, url).with(body: { run_id: "r1", status: "completed" }.to_json)
  end

  it "returns false and logs on connection failure (after retries)" do
    stub_request(:post, url).to_raise(Faraday::ConnectionFailed.new("boom"))
    expect(logger).to receive(:error).with(hash_including(event: "webhook.failed"))
    delivery = described_class.new(url: url, logger: logger)
    expect(delivery.deliver({ run_id: "r1" })).to be(false)
  end

  it "returns false when no URL is configured" do
    delivery = described_class.new(url: nil, logger: logger)
    expect(delivery.deliver({})).to be(false)
  end
end
