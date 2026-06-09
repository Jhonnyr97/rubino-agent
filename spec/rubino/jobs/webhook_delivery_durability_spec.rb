# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "openssl"
require "json"

RSpec.describe Rubino::Jobs::WebhookDelivery do
  let(:url) { "https://example.test/hook" }
  let(:logger) { instance_double(Rubino::Logger, info: nil, error: nil, warn: nil) }
  let(:secret) { "shh-it-is-a-secret" }
  let(:db) { test_database.db }
  let(:sleeper) { ->(_s) {} } # no wall-time sleep during specs

  def build(**overrides)
    described_class.new(
      url: url,
      logger: logger,
      db: db,
      secret: secret,
      sleeper: sleeper,
      **overrides
    )
  end

  describe "persistence + idempotency" do
    it "persists a webhook_deliveries row with unique request_id and matching payload_sha256" do
      stub_request(:post, url).to_return(status: 200, body: "ok")
      payload = { run_id: "r1", status: "completed" }

      build.deliver(payload, job_id: "j1", run_id: "r1")

      rows = db[:webhook_deliveries].all
      expect(rows.size).to eq(1)
      row = rows.first
      expect(row[:request_id]).to match(/\A[0-9a-f-]{36}\z/)
      expect(row[:payload_sha256]).to eq(Digest::SHA256.hexdigest(JSON.generate(payload)))
      expect(row[:status]).to eq("delivered")
      expect(row[:attempt_count]).to eq(1)
      expect(row[:job_id]).to eq("j1")
    end

    it "emits a unique X-Rubino-Delivery-Id per delivery (different attempt-sets get different IDs)" do
      stub_request(:post, url).to_return(status: 200, body: "ok")

      build.deliver({ a: 1 })
      build.deliver({ a: 2 })

      ids = db[:webhook_deliveries].select(:request_id).map { |r| r[:request_id] }
      expect(ids.uniq.size).to eq(2)
    end

    it "reuses the same X-Rubino-Delivery-Id across retries of the same attempt-set" do
      seen_ids = []
      stub_request(:post, url).to_return do |req|
        seen_ids << req.headers["X-Rubino-Delivery-Id"]
        { status: 500, body: "" }
      end

      build.deliver({ a: 1 })

      expect(seen_ids.size).to eq(3)
      expect(seen_ids.uniq.size).to eq(1)
    end
  end

  describe "HMAC signing" do
    it "signs the body with HMAC-SHA256 under the configured secret" do
      stub_request(:post, url).to_return(status: 200, body: "ok")
      payload = { run_id: "r1" }
      expected_body = JSON.generate(payload)
      expected_sig = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, expected_body)}"

      build.deliver(payload)

      expect(WebMock).to(have_requested(:post, url).with do |req|
        req.headers["X-Rubino-Signature"] == expected_sig
      end)
    end

    it "omits the signature header when no secret is configured" do
      stub_request(:post, url).to_return(status: 200, body: "ok")
      build(secret: nil).deliver({ a: 1 })
      expect(WebMock).to(have_requested(:post, url).with do |req|
        !req.headers.key?("X-Rubino-Signature")
      end)
    end
  end

  describe "retry policy" do
    it "retries up to 3 attempts on HTTP failure, sleeping with the documented backoff" do
      stub_request(:post, url).to_return(status: 500, body: "")
      slept = []
      result = build(sleeper: ->(s) { slept << s }).deliver({ a: 1 })

      expect(result).to be(false)
      expect(WebMock).to have_requested(:post, url).times(3)
      expect(slept).to eq([5, 30])
    end

    it "marks the row as dead after 3 consecutive failures" do
      stub_request(:post, url).to_return(status: 500, body: "")
      build.deliver({ a: 1 })

      row = db[:webhook_deliveries].first
      expect(row[:status]).to eq("dead")
      expect(row[:attempt_count]).to eq(3)
    end

    it "stops retrying as soon as a 2xx arrives" do
      stub_request(:post, url)
        .to_return({ status: 500 }, { status: 200, body: "ok" })

      result = build.deliver({ a: 1 })

      expect(result).to be(true)
      expect(WebMock).to have_requested(:post, url).times(2)
      row = db[:webhook_deliveries].first
      expect(row[:status]).to eq("delivered")
      expect(row[:attempt_count]).to eq(2)
    end
  end

  describe "#resume_pending!" do
    it "replays pending rows whose scheduled_at has passed and marks them delivered on success" do
      stub_request(:post, url).to_return(status: 200, body: "ok")
      now = Time.now.utc.iso8601
      db[:webhook_deliveries].insert(
        id: "row-1",
        job_id: "j1",
        run_id: "r1",
        target_url: url,
        request_id: "req-resume-1",
        payload_sha256: Digest::SHA256.hexdigest('{"a":1}'),
        payload_json: '{"a":1}',
        attempt_count: 0,
        status: "pending",
        scheduled_at: now,
        created_at: now,
        updated_at: now
      )

      delivery = build
      scheduled = delivery.resume_pending!
      expect(scheduled).to eq(1)
      # Resume hands off to Thread.new; wait until the row settles.
      deadline = Time.now + 2
      sleep(0.01) while db[:webhook_deliveries].where(id: "row-1").get(:status) == "pending" && Time.now < deadline

      row = db[:webhook_deliveries].where(id: "row-1").first
      expect(row[:status]).to eq("delivered")
      expect(WebMock).to have_requested(:post, url).with(headers: { "X-Rubino-Delivery-Id" => "req-resume-1" })
    end

    it "ignores rows scheduled in the future" do
      future = (Time.now + 3600).utc.iso8601
      now = Time.now.utc.iso8601
      db[:webhook_deliveries].insert(
        id: "row-future",
        target_url: url,
        request_id: "req-future",
        payload_sha256: "x",
        payload_json: "{}",
        attempt_count: 0,
        status: "pending",
        scheduled_at: future,
        created_at: now,
        updated_at: now
      )

      expect(build.resume_pending!).to eq(0)
    end
  end
end
