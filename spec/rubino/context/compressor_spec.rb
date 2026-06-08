# frozen_string_literal: true

# Smoke-level specs for Context::Compressor — the compaction orchestrator.
# Compaction runs on every long session; silent breakage = lost context
# (audit issue #15). Specs cover the no-op short-circuit and the happy path
# via collaborator stubs (avoids needing a full DB fixture).

RSpec.describe Rubino::Context::Compressor do
  let(:config) { Rubino.configuration }
  let(:session_id) { "sess-abc" }

  describe "#compact!" do
    let(:session_repo) { instance_double(Rubino::Session::Repository) }
    let(:message_store) { instance_double(Rubino::Session::Store) }

    before do
      allow(Rubino::Session::Repository).to receive(:new).and_return(session_repo)
      allow(Rubino::Session::Store).to receive(:new).and_return(message_store)
    end

    it "raises CompactionError when the session is missing" do
      allow(session_repo).to receive(:find).with(session_id).and_return(nil)
      expect {
        described_class.new(session_id: session_id, config: config, db: double).compact!
      }.to raise_error(Rubino::CompactionError, /Session not found/)
    end

    it "returns a skipped result when message count is below the minimum" do
      allow(session_repo).to receive(:find).with(session_id).and_return({ id: session_id })
      allow(message_store).to receive(:for_session).with(session_id).and_return([])

      compressor = described_class.new(session_id: session_id, config: config, db: double)
      result = compressor.compact!

      expect(result[:skipped]).to be true
      expect(result[:saved_tokens]).to eq(0)
      expect(result[:source_session_id]).to eq(session_id)
    end
  end

  # Regression for the metadata-dropping compaction bug: create_child_session
  # used to copy only role/content/tool_name/tool_call_id, silently dropping
  # metadata[:tool_calls] (and token_count on the head). That orphaned the
  # assistant toolUse block and 400'd strict providers when the child resumed.
  describe "#create_child_session (faithful copy)" do
    let(:db_connection) { test_database }
    let(:db) { db_connection.db }
    let(:store) { Rubino::Session::Store.new(db: db) }
    let(:repo) { Rubino::Session::Repository.new(db: db) }
    let(:parent) { repo.create(source: "test", model: "m", provider: "p") }

    def assistant_with_call(id)
      store.create(
        session_id: parent[:id], role: "assistant", content: "calling",
        token_count: 42,
        metadata: { tool_calls: [{ id: id, name: "shell", arguments: { cmd: "ls" } }] }
      )
    end

    it "preserves metadata[:tool_calls] and token_count into head and tail" do
      assistant_with_call("call_head")
      store.create(session_id: parent[:id], role: "tool", content: "head out", tool_call_id: "call_head")
      assistant_with_call("call_tail")
      store.create(session_id: parent[:id], role: "tool", content: "tail out", tool_call_id: "call_tail")

      compressor = described_class.new(session_id: parent[:id], config: config, db: db)
      head = store.for_session(parent[:id]).first(2)
      tail = store.for_session(parent[:id]).last(2)

      child = compressor.send(:create_child_session, parent, head, "SUMMARY", tail)
      copied = store.for_session(child[:id])

      asst = copied.select { |m| m.role == "assistant" }
      expect(asst.map { |m| m.metadata[:tool_calls].first[:id] }).to eq(%w[call_head call_tail])
      expect(asst.map(&:token_count)).to all(eq(42))
    end

    # Regression for the lineage-drift bug: summaries persisted by compaction
    # must chain parent_summary_id to the prior summary, and the compaction
    # row's previous_summary_id must point at that prior summary (NOT at the
    # row just inserted — the old #previous_summary_id re-queried after insert).
    it "chains summary lineage and records the prior summary on the compaction" do
      # Small protect windows so a modest message count yields a non-empty middle.
      lineage_config = test_configuration(
        "compression" => Rubino::Config::Defaults.to_hash["compression"]
          .merge("protect_first_n" => 1, "protect_last_n" => 1)
      )

      prior_id = Rubino::Session::SummaryStore.new(db: db)
                                                 .insert(session_id: parent[:id], content: "PRIOR")

      # Enough messages to clear the minimum + a non-empty middle.
      15.times { |i| store.create(session_id: parent[:id], role: "user", content: "m#{i}") }

      builder = instance_double(Rubino::Context::SummaryBuilder, build: "NEW SUMMARY")
      allow(Rubino::Context::SummaryBuilder).to receive(:new).and_return(builder)
      allow_any_instance_of(Rubino::Memory::Flusher)
        .to receive(:flush_before_compaction!)

      result = described_class.new(session_id: parent[:id], config: lineage_config, db: db).compact!

      new_summary = db[:session_summaries].where(id: result[:summary_id]).first
      expect(new_summary[:content]).to eq("NEW SUMMARY")
      expect(new_summary[:parent_summary_id]).to eq(prior_id)

      compaction = db[:compactions].where(new_summary_id: result[:summary_id]).first
      expect(compaction[:previous_summary_id]).to eq(prior_id)
    end

    it "produces a child wire list with no orphan tool pairs" do
      assistant_with_call("call_head")
      store.create(session_id: parent[:id], role: "tool", content: "head out", tool_call_id: "call_head")
      assistant_with_call("call_tail")
      store.create(session_id: parent[:id], role: "tool", content: "tail out", tool_call_id: "call_tail")

      compressor = described_class.new(session_id: parent[:id], config: config, db: db)
      head = store.for_session(parent[:id]).first(2)
      tail = store.for_session(parent[:id]).last(2)
      child = compressor.send(:create_child_session, parent, head, "SUMMARY", tail)

      allow(Rubino).to receive(:database).and_return(db_connection)
      assembler = Rubino::Context::PromptAssembler.new(
        session: { id: child[:id] }, memory_context: {}, config: config
      )
      wire = assembler.build

      declared = wire.flat_map { |m| Array(m[:tool_calls]).map { |tc| tc[:id] } }.compact
      results = wire.select { |m| m[:role] == "tool" }.map { |m| m[:tool_call_id] }
      expect(results - declared).to be_empty
      expect(declared.sort).to eq(%w[call_head call_tail])
    end
  end
end
