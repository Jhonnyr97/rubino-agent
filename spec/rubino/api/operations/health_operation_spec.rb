# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::HealthOperation do
  before { with_test_db }

  it "returns 200 with deps when db + scheduler are up" do
    scheduler = instance_double(Rubino::Jobs::Scheduler, scheduled_count: 3)
    allow(Rubino::Jobs::Scheduler).to receive(:instance).and_return(scheduler)
    status, body = described_class.call(make_request)
    expect(status).to eq(200)
    expect(body[:status]).to eq("ok")
    expect(body[:deps][:db][:status]).to eq("ok")
    expect(body[:deps][:scheduler][:status]).to eq("ok")
    expect(body[:deps][:scheduler][:scheduled_jobs]).to eq(3)
    expect(body[:version]).to eq(Rubino::VERSION)
  end

  it "reports scheduler down without raising when scheduled_count fails" do
    scheduler = instance_double(Rubino::Jobs::Scheduler)
    allow(scheduler).to receive(:scheduled_count).and_raise(StandardError, "boom")
    allow(Rubino::Jobs::Scheduler).to receive(:instance).and_return(scheduler)

    status, body = described_class.call(make_request)
    expect(status).to eq(503)
    expect(body[:deps][:scheduler][:status]).to eq("down")
  end

  it "returns 503 when the database is unreachable" do
    db = instance_double(Sequel::Database)
    allow(db).to receive(:test_connection).and_raise(StandardError, "connection refused")
    allow(Rubino.database).to receive(:db).and_return(db)
    allow(Rubino::Jobs::Scheduler).to receive(:instance)
      .and_return(instance_double(Rubino::Jobs::Scheduler, scheduled_count: 0))

    status, body = described_class.call(make_request)
    expect(status).to eq(503)
    expect(body[:status]).to eq("degraded")
    expect(body[:deps][:db][:status]).to eq("down")
  end
end
