# frozen_string_literal: true

# Regression guard for #554: short sessions (fewer turns than
# memory.auto_extract_interval, default 10) never crossed the turn-based
# extract gate, so a fact stated in a 2-3 turn chat was silently dropped and
# the "tell a fact one session, recall it the next" workflow failed. The
# end-of-session flush (Flusher#flush_on_session_end!, wired into
# Runner#end_session!) is the catch-all that mines any un-extracted turns once
# on a clean close — bounded by the per-session extraction watermark and gated
# on memory.enabled + memory.auto_extract.
RSpec.describe Rubino::Memory::Flusher do
  let(:db_connection) { test_database }

  # Always-on memory config so the gate predicates pass unless a test overrides.
  def enabled_config
    test_configuration("memory" => { "enabled" => true, "auto_extract" => true })
  end

  describe "#flush_on_session_end! — gates" do
    let(:backend) { instance_double(Rubino::Memory::Backends::Sqlite) }

    it "mines the session's un-extracted turns through the backend extract path" do
      allow(backend).to receive(:extract).with("sess-1").and_return([{ id: "m1" }, { id: "m2" }])

      result = described_class.new(backend: backend, config: enabled_config)
                              .flush_on_session_end!("sess-1")

      expect(backend).to have_received(:extract).with("sess-1")
      expect(result).to eq(flushed_count: 2, session_id: "sess-1")
    end

    it "does NOT extract when memory is disabled" do
      cfg = test_configuration("memory" => { "enabled" => false, "auto_extract" => true })
      expect(backend).not_to receive(:extract)

      result = described_class.new(backend: backend, config: cfg).flush_on_session_end!("sess-1")
      expect(result).to eq(flushed_count: 0, session_id: "sess-1")
    end

    it "does NOT extract when auto_extract is off" do
      cfg = test_configuration("memory" => { "enabled" => true, "auto_extract" => false })
      expect(backend).not_to receive(:extract)

      result = described_class.new(backend: backend, config: cfg).flush_on_session_end!("sess-1")
      expect(result).to eq(flushed_count: 0, session_id: "sess-1")
    end

    it "is best-effort: a backend error is swallowed, never breaking the exit" do
      allow(backend).to receive(:extract).and_raise(StandardError, "boom")

      result = described_class.new(backend: backend, config: enabled_config)
                              .flush_on_session_end!("sess-1")
      expect(result).to eq(flushed_count: 0, session_id: "sess-1")
    end
  end

  describe "#flush_on_session_end! — watermark idempotency (real sqlite backend)" do
    let(:config) do
      test_configuration("memory" => { "enabled" => true, "auto_extract" => true, "backend" => "sqlite" })
    end
    # Stubbed aux client so no real LLM is hit; #call returns a response whose
    # #content is the extractor's JSON. Tests set the facts via `aux_facts`.
    let(:aux_facts) { [{ "text" => "User deploys with Kamal", "kind" => "preference" }] }
    let(:aux_client) do
      response = double("AdapterResponse", content: JSON.generate("add" => aux_facts, "supersede" => []))
      client = instance_double(Rubino::LLM::AuxiliaryClient)
      allow(client).to receive(:call).and_return(response)
      client
    end
    let(:backend) do
      Rubino::Memory::Backends::Sqlite.new(config: config, db: db_connection.db, aux_client: aux_client)
    end
    let(:session_store) { Rubino::Session::Store.new(db: db_connection.db) }
    let(:session_repo) { Rubino::Session::Repository.new(db: db_connection.db) }
    let(:session_id) { session_repo.create(source: "test")[:id] }

    before do
      # A 3-turn short session that states a durable fact — well under the
      # default 10-turn auto_extract_interval, so the turn gate never fired.
      session_store.create(session_id: session_id, role: "user",
                           content: "I always deploy with Kamal, never Capistrano.")
      session_store.create(session_id: session_id, role: "assistant", content: "Noted.")
      session_store.create(session_id: session_id, role: "user", content: "Thanks!")
    end

    it "extracts the short-session fact on session end (3-turn fact IS captured)" do
      result = described_class.new(backend: backend, config: config).flush_on_session_end!(session_id)

      expect(result[:flushed_count]).to eq(1)
      expect(backend.count).to eq(1)
      expect(backend.list.first[:content]).to eq("User deploys with Kamal")
    end

    it "the watermark prevents re-extraction: a second flush mines nothing new" do
      flusher = described_class.new(backend: backend, config: config)

      first = flusher.flush_on_session_end!(session_id)
      second = flusher.flush_on_session_end!(session_id)

      expect(first[:flushed_count]).to eq(1)
      expect(second[:flushed_count]).to eq(0) # watermark advanced — no un-mined turns
      expect(backend.count).to eq(1)          # no duplicate fact minted
    end

    it "no double-extract when the interval/compaction flush already mined the turns" do
      # Simulate the 10-turn-interval (or compaction) extract having already run.
      backend.extract(session_id)
      expect(backend.count).to eq(1)

      # Session-end flush now finds nothing past the watermark.
      result = described_class.new(backend: backend, config: config).flush_on_session_end!(session_id)
      expect(result[:flushed_count]).to eq(0)
      expect(backend.count).to eq(1)
    end
  end
end
