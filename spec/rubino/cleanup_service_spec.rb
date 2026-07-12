# frozen_string_literal: true

RSpec.describe Rubino::CleanupService do
  let(:home) { Dir.mktmpdir("cleanup_service_spec") }

  before do
    allow(Rubino).to receive(:home_path).and_return(home)
    with_test_db
  end

  after { FileUtils.rm_rf(home) }

  # Seed a session row with the given status, ended_at, and id.
  def seed_session(id:, status:, ended_at: nil, **extra)
    row = {
      id: id,
      title: "Session #{id}",
      model: "gpt-4",
      provider: "openai",
      status: status,
      cwd: "/tmp",
      created_at: (ended_at ? (ended_at - 86_400).iso8601 : Time.now.utc.iso8601),
      updated_at: Time.now.utc.iso8601,
      message_count: 1,
      source: "chat"
    }.merge(extra)
    row[:ended_at] = ended_at.iso8601 if ended_at
    Rubino.database.db[:sessions].insert(row)
    row
  end

  def all_session_ids
    Rubino.database.db[:sessions].select_map(:id)
  end

  describe ".run_once — retention cutoff" do
    it "deletes ended sessions older than period_days, keeps recent ones" do
      seed_session(id: "old", status: "ended", ended_at: Time.now - (35 * 86_400))
      seed_session(id: "recent", status: "ended", ended_at: Time.now - (5 * 86_400))

      config = test_configuration("cleanup" => { "period_days" => 30, "min_retention_days" => 1 })
      allow(Rubino).to receive(:configuration).and_return(config)

      described_class.run_once(now: Time.now)

      expect(all_session_ids).not_to include("old")
      expect(all_session_ids).to include("recent")
    end

    it "honours the default 30-day retention" do
      seed_session(id: "old32", status: "ended", ended_at: Time.now - (32 * 86_400))
      seed_session(id: "day28", status: "ended", ended_at: Time.now - (28 * 86_400))

      config = test_configuration # defaults: period_days=30, min_retention_days=1
      allow(Rubino).to receive(:configuration).and_return(config)

      described_class.run_once(now: Time.now)

      expect(all_session_ids).not_to include("old32")
      expect(all_session_ids).to include("day28")
    end
  end

  describe ".run_once — minRetention floor" do
    it "never deletes anything newer than min_retention_days, even if ended" do
      # A session ended 2 days ago — past a period_days=1 but min_retention_days=3
      # should protect it.
      seed_session(id: "fresh", status: "ended", ended_at: Time.now - (2 * 86_400))

      config = test_configuration("cleanup" => { "period_days" => 1, "min_retention_days" => 3 })
      allow(Rubino).to receive(:configuration).and_return(config)

      described_class.run_once(now: Time.now)

      expect(all_session_ids).to include("fresh")
    end
  end

  describe ".run_once — active/compacting protection" do
    it "never deletes active sessions regardless of age" do
      seed_session(id: "active", status: "active", ended_at: Time.now - (60 * 86_400))

      config = test_configuration("cleanup" => { "period_days" => 30, "min_retention_days" => 1 })
      allow(Rubino).to receive(:configuration).and_return(config)

      described_class.run_once(now: Time.now)

      expect(all_session_ids).to include("active")
    end

    it "never deletes compacting sessions regardless of age" do
      seed_session(id: "compacting", status: "compacting", ended_at: Time.now - (60 * 86_400))

      config = test_configuration("cleanup" => { "period_days" => 30, "min_retention_days" => 1 })
      allow(Rubino).to receive(:configuration).and_return(config)

      described_class.run_once(now: Time.now)

      expect(all_session_ids).to include("compacting")
    end
  end

  describe ".run_once — config OFF" do
    it "does nothing when period_days is nil" do
      seed_session(id: "old", status: "ended", ended_at: Time.now - (60 * 86_400))

      config = test_configuration("cleanup" => { "period_days" => nil, "min_retention_days" => 1 })
      allow(Rubino).to receive(:configuration).and_return(config)

      described_class.run_once(now: Time.now)

      expect(all_session_ids).to include("old")
    end

    it "does nothing when period_days is false" do
      seed_session(id: "old", status: "ended", ended_at: Time.now - (60 * 86_400))

      config = test_configuration("cleanup" => { "period_days" => false, "min_retention_days" => 1 })
      allow(Rubino).to receive(:configuration).and_return(config)

      described_class.run_once(now: Time.now)

      expect(all_session_ids).to include("old")
    end

    it "does nothing when period_days is 0" do
      seed_session(id: "old", status: "ended", ended_at: Time.now - (60 * 86_400))

      config = test_configuration("cleanup" => { "period_days" => 0, "min_retention_days" => 1 })
      allow(Rubino).to receive(:configuration).and_return(config)

      described_class.run_once(now: Time.now)

      expect(all_session_ids).to include("old")
    end

    it "does nothing when period_days is negative" do
      seed_session(id: "old", status: "ended", ended_at: Time.now - (60 * 86_400))

      config = test_configuration("cleanup" => { "period_days" => -5, "min_retention_days" => 1 })
      allow(Rubino).to receive(:configuration).and_return(config)

      described_class.run_once(now: Time.now)

      expect(all_session_ids).to include("old")
    end
  end

  describe ".run_once — throttle" do
    it "skips when cleanup ran less than 24h ago" do
      seed_session(id: "old", status: "ended", ended_at: Time.now - (60 * 86_400))

      config = test_configuration("cleanup" => { "period_days" => 30, "min_retention_days" => 1 })
      allow(Rubino).to receive(:configuration).and_return(config)

      # Write a throttle file from 1 hour ago.
      throttle_file = File.join(home, "cleanup_last_run")
      File.write(throttle_file, (Time.now - 3600).utc.iso8601)

      described_class.run_once(now: Time.now)

      # The old session should NOT be deleted — throttle blocked cleanup.
      expect(all_session_ids).to include("old")
    end

    it "runs when throttle file is older than 24h" do
      seed_session(id: "old", status: "ended", ended_at: Time.now - (60 * 86_400))

      config = test_configuration("cleanup" => { "period_days" => 30, "min_retention_days" => 1 })
      allow(Rubino).to receive(:configuration).and_return(config)

      # Write a throttle file from 25 hours ago.
      throttle_file = File.join(home, "cleanup_last_run")
      File.write(throttle_file, (Time.now - (25 * 3600)).utc.iso8601)

      described_class.run_once(now: Time.now)

      expect(all_session_ids).not_to include("old")
    end
  end

  describe ".run_once — non-fatal" do
    it "does not raise when the DB query explodes" do
      config = test_configuration("cleanup" => { "period_days" => 30, "min_retention_days" => 1 })
      allow(Rubino).to receive(:configuration).and_return(config)

      allow(Rubino.database.db).to receive(:[]).and_raise(StandardError, "boom")

      expect { described_class.run_once(now: Time.now) }.not_to raise_error
    end
  end
end
