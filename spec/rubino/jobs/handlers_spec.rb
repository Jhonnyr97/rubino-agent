# frozen_string_literal: true

# Contract-level specs for the 4 lifecycle job handlers. They run on the hot
# path of every long session, so silent breakage = corrupted sessions / lost
# memories / unbounded session table growth. These specs verify each handler
# delegates to the expected collaborator with the right id (audit issue #15).

RSpec.describe "Rubino::Jobs::Handlers" do
  describe Rubino::Jobs::Handlers::CompactSessionJob do
    it "delegates to Context::Compressor for the given session_id" do
      compressor = instance_double(Rubino::Context::Compressor, compact!: { ok: true })
      expect(Rubino::Context::Compressor)
        .to receive(:new).with(session_id: "sid-123").and_return(compressor)
      described_class.new.perform(session_id: "sid-123")
    end

    it "is a no-op when session_id is missing" do
      expect(Rubino::Context::Compressor).not_to receive(:new)
      expect { described_class.new.perform({}) }.not_to raise_error
    end
  end

  describe Rubino::Jobs::Handlers::ExtractMemoryJob do
    it "delegates to the configured memory backend for the given session_id" do
      backend = instance_double(Rubino::Memory::Backends::Default, extract: [])
      expect(Rubino::Memory::Backends).to receive(:build).and_return(backend)
      expect(backend).to receive(:extract).with("sid-9")
      described_class.new.perform(session_id: "sid-9")
    end

    it "is a no-op when session_id is missing" do
      expect(Rubino::Memory::Backends).not_to receive(:build)
      described_class.new.perform({})
    end
  end

  describe Rubino::Jobs::Handlers::SummarizeSessionJob do
    it "delegates to Context::SummaryBuilder for the given session_id" do
      builder = instance_double(Rubino::Context::SummaryBuilder, build_and_save!: nil)
      expect(Rubino::Context::SummaryBuilder)
        .to receive(:new).with(session_id: "sid-77").and_return(builder)
      described_class.new.perform(session_id: "sid-77")
    end

    it "is a no-op when session_id is missing" do
      expect(Rubino::Context::SummaryBuilder).not_to receive(:new)
      described_class.new.perform({})
    end
  end

  describe Rubino::Jobs::Handlers::CleanupSessionsJob do
    let(:db_double) { double("DB") }
    let(:dataset)   { double("Dataset") }
    let(:repo)      { instance_double(Rubino::Session::Repository) }

    before do
      database = double("Database", db: db_double)
      allow(Rubino).to receive(:database).and_return(database)
      allow(Rubino::Session::Repository).to receive(:new).and_return(repo)
    end

    it "destroys ended sessions older than the retention cutoff" do
      old_sessions = [{ id: "old-1" }, { id: "old-2" }]
      expect(db_double).to receive(:[]).with(:sessions).and_return(dataset)
      expect(dataset).to receive(:where).with(status: "ended").and_return(dataset)
      expect(dataset).to receive(:where).and_return(dataset)
      expect(dataset).to receive(:select).with(:id).and_return(dataset)
      expect(dataset).to receive(:all).and_return(old_sessions)

      expect(repo).to receive(:destroy!).with("old-1")
      expect(repo).to receive(:destroy!).with("old-2")

      described_class.new.perform(retention_days: 7)
    end

    it "uses the default retention when none is provided" do
      expect(db_double).to receive(:[]).with(:sessions).and_return(dataset)
      allow(dataset).to receive(:where).and_return(dataset)
      allow(dataset).to receive(:select).and_return(dataset)
      allow(dataset).to receive(:all).and_return([])
      expect { described_class.new.perform({}) }.not_to raise_error
    end
  end
end
