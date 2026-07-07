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
      expect do
        described_class.new(session_id: session_id, config: config, db: double).compact!
      end.to raise_error(Rubino::CompactionError, /Session not found/)
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

    # #420: a skipped (too-few-messages) compaction now carries the THRESHOLD so
    # the CLI / in-chat notice can state "needs >= N messages" instead of a
    # vague "too few", which left the user unable to tell when it would work.
    it "a skipped result carries the minimum_messages threshold (#420)" do
      allow(session_repo).to receive(:find).with(session_id).and_return({ id: session_id })
      allow(message_store).to receive(:for_session).with(session_id).and_return([])

      result = described_class.new(session_id: session_id, config: config, db: double).compact!

      expected = config.dig("compression", "protect_first_n") + config.dig("compression", "protect_last_n") + 5
      expect(result[:minimum_messages]).to eq(expected)
    end
  end

  # The below-threshold NO-OP gate (#425): the manual /compact used to bypass
  # the token-budget gate the auto path enforces, so a small session ran a paid
  # summary whose inserted text was LARGER than the middle it replaced —
  # growing context, reporting a false saving, and silently forking the session.
  describe "#compact! below the token threshold" do
    let(:db_connection) { test_database }
    let(:db) { db_connection.db }
    let(:store) { Rubino::Session::Store.new(db: db) }
    let(:repo) { Rubino::Session::Repository.new(db: db) }
    let(:parent) { repo.create(source: "test", model: "m", provider: "p") }

    it "no-ops with reason :below_threshold — no summary call, no child fork" do
      # 40 messages clears the minimum-messages floor (28), but the transcript is
      # nowhere near the 64K compaction threshold (default window 128K).
      40.times { |i| store.create(session_id: parent[:id], role: "user", content: "short #{i}") }

      builder = instance_spy(Rubino::Context::SummaryBuilder)
      allow(Rubino::Context::SummaryBuilder).to receive(:new).and_return(builder)
      sessions_before = db[:sessions].count

      result = described_class.new(session_id: parent[:id], config: config, db: db).compact!

      expect(result[:skipped]).to be true
      expect(result[:reason]).to eq(:below_threshold)
      expect(result[:target_session_id]).to be_nil # no child forked
      expect(result[:saved_tokens]).to eq(0)
      expect(builder).not_to have_received(:build) # no paid summary call
      expect(db[:sessions].count).to eq(sessions_before) # no child session row
      expect(repo.find(parent[:id])[:status]).not_to eq("compacted")
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

    # MEM-2: the child starts with a NULL extraction cursor; without seeding it
    # would re-mine the ENTIRE copied head+summary+tail on its first turn. The
    # compactor must pin the watermark to the child's last copied message.
    it "seeds the child's memory-extraction cursor past the copied transcript" do
      4.times { |i| store.create(session_id: parent[:id], role: "user", content: "m#{i}") }
      head = store.for_session(parent[:id]).first(2)
      tail = store.for_session(parent[:id]).last(2)

      compressor = described_class.new(session_id: parent[:id], config: config, db: db)
      child = compressor.send(:create_child_session, parent, head, "SUMMARY", tail)

      cursor = db[:sessions].where(id: child[:id]).get(:memory_extracted_msg_id)
      # Seeded to the child's last copied message (the watermark column is now
      # inert bookkeeping, but the seed path still runs uniformly across
      # fork/branch/compaction).
      expect(cursor).to eq(store.last_id(child[:id]))
    end

    # R1-M1: copy_into/create write message rows but never touch the session's
    # denormalized message_count, so the compaction child showed "Messages 0" in
    # `sessions list` despite a populated transcript. The compactor must sync it.
    it "syncs the child's message_count to its real transcript size" do
      4.times { |i| store.create(session_id: parent[:id], role: "user", content: "m#{i}") }
      head = store.for_session(parent[:id]).first(2)
      tail = store.for_session(parent[:id]).last(2)

      compressor = described_class.new(session_id: parent[:id], config: config, db: db)
      child = compressor.send(:create_child_session, parent, head, "SUMMARY", tail)

      real_count = store.count(child[:id]) # head + summary + tail = 5
      expect(real_count).to eq(5)
      expect(db[:sessions].where(id: child[:id]).get(:message_count)).to eq(real_count)
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
      # These specs exercise the post-gate mechanics (lineage / short-id / atomic
      # rollback) on a few short messages that fall under the 64K compaction
      # floor, so force the budget gate true — the dedicated specs above cover
      # the below-threshold NO-OP itself.
      allow_any_instance_of(Rubino::Context::TokenBudget)
        .to receive(:needs_compaction?).and_return(true)

      prior_id = Rubino::Session::SummaryStore.new(db: db)
                                              .insert(session_id: parent[:id], content: "PRIOR")

      # Enough messages to clear the minimum + a non-empty middle.
      15.times { |i| store.create(session_id: parent[:id], role: "user", content: "m#{i}") }

      builder = instance_double(Rubino::Context::SummaryBuilder, build: "NEW SUMMARY")
      allow(Rubino::Context::SummaryBuilder).to receive(:new).and_return(builder)

      result = described_class.new(session_id: parent[:id], config: lineage_config, db: db).compact!

      new_summary = db[:session_summaries].where(id: result[:summary_id]).first
      expect(new_summary[:content]).to eq("NEW SUMMARY")
      expect(new_summary[:parent_summary_id]).to eq(prior_id)

      compaction = db[:compactions].where(new_summary_id: result[:summary_id]).first
      expect(compaction[:previous_summary_id]).to eq(prior_id)
    end

    # #332 [MED]: steps 6-8 (summary insert → child create+copy → lineage
    # record) must be atomic. A raise mid-compaction (here: during the child
    # message copy) used to leave an orphan child row AND a dangling summary
    # row, half-mutating the parent — the next resume then found a partial,
    # incoherent child. Wrapping 6-8 in one transaction rolls it ALL back.
    it "rolls back the summary and child on a crash mid-compaction (atomic)" do
      lineage_config = test_configuration(
        "compression" => Rubino::Config::Defaults.to_hash["compression"]
                                                 .merge("protect_first_n" => 1, "protect_last_n" => 1)
      )
      # These specs exercise the post-gate mechanics (lineage / short-id / atomic
      # rollback) on a few short messages that fall under the 64K compaction
      # floor, so force the budget gate true — the dedicated specs above cover
      # the below-threshold NO-OP itself.
      allow_any_instance_of(Rubino::Context::TokenBudget)
        .to receive(:needs_compaction?).and_return(true)
      15.times { |i| store.create(session_id: parent[:id], role: "user", content: "m#{i}") }

      allow(Rubino::Context::SummaryBuilder).to receive(:new).and_return(
        instance_double(Rubino::Context::SummaryBuilder, build: "NEW SUMMARY")
      )

      summaries_before = db[:session_summaries].count
      sessions_before  = db[:sessions].count

      compressor = described_class.new(session_id: parent[:id], config: lineage_config, db: db)
      # Blow up DURING the child copy (step 7), after the summary insert (step 6).
      allow(compressor).to receive(:create_child_session).and_raise(RuntimeError, "copy boom")

      expect { compressor.compact! }.to raise_error(RuntimeError, /copy boom/)

      # No dangling summary, no orphan child, parent untouched.
      expect(db[:session_summaries].count).to eq(summaries_before)
      expect(db[:sessions].count).to eq(sessions_before)
      expect(db[:sessions].where(id: parent[:id]).get(:status)).to eq("active")
      expect(db[:compactions].count).to eq(0)
    end

    # #415a anti-thrash back-off: a session hovering at the threshold re-pays a
    # summary call every turn. After two compactions that each saved <10% of
    # their original tokens, #thrashing? returns true so the auto path skips.
    describe "#thrashing? (anti-thrash back-off)" do
      def record_compaction(source:, original:, saved:, created_at: Time.now.utc.iso8601)
        db[:compactions].insert(
          id: SecureRandom.uuid,
          source_session_id: source, target_session_id: SecureRandom.uuid,
          original_token_count: original, saved_token_count: saved,
          created_at: created_at
        )
      end

      it "is false with no prior compactions" do
        compressor = described_class.new(session_id: parent[:id], config: config, db: db)
        expect(compressor.thrashing?).to be false
      end

      it "is true when the last two compactions each saved <10%" do
        record_compaction(source: parent[:id], original: 100_000, saved: 5_000) # 5%
        record_compaction(source: parent[:id], original: 100_000, saved: 9_000) # 9%
        compressor = described_class.new(session_id: parent[:id], config: config, db: db)
        expect(compressor.thrashing?).to be true
      end

      it "is false when a recent compaction was effective (>=10%)" do
        record_compaction(source: parent[:id], original: 100_000, saved: 5_000)  # 5%
        record_compaction(source: parent[:id], original: 100_000, saved: 40_000) # 40%
        compressor = described_class.new(session_id: parent[:id], config: config, db: db)
        expect(compressor.thrashing?).to be false
      end

      # BUG-THRASH-TIEBREAK: created_at is iso8601 truncated to SECONDS and the
      # PK is a random UUID, so when 3+ compactions land in the SAME wall-clock
      # second `reverse(:created_at).limit(2)` is non-deterministic — it could
      # return the two OLD ineffective rows and MISS the newest EFFECTIVE one,
      # leaving #thrashing? wrongly true and the back-off stuck on. Ordering by
      # the insertion-monotonic SQLite rowid as a tiebreaker makes "the 2 most
      # recent" unambiguous: here the newest (effective 50%) row must be in the
      # window, so #thrashing? is false.
      it "is false when the NEWEST same-second compaction was effective (tiebreak)" do
        same_second = "2026-06-15T12:00:00Z"
        # Insert oldest-first so rowid order matches insertion order. The two
        # OLD rows are ineffective; the NEWEST (last inserted) is effective.
        record_compaction(source: parent[:id], original: 100_000, saved: 5_000,  created_at: same_second) # 5%
        record_compaction(source: parent[:id], original: 100_000, saved: 4_000,  created_at: same_second) # 4%
        record_compaction(source: parent[:id], original: 100_000, saved: 50_000, created_at: same_second) # 50% (newest)

        compressor = described_class.new(session_id: parent[:id], config: config, db: db)
        # The 2 most recent = the 50% row + its neighbor, NOT the 2 oldest.
        expect(compressor.thrashing?).to be false
      end

      it "follows the parent lineage chain across compaction children" do
        child = repo.create(source: "compaction", model: "m", provider: "p",
                            parent_session_id: parent[:id])
        record_compaction(source: parent[:id], original: 100_000, saved: 1_000) # 1%
        record_compaction(source: child[:id], original: 100_000, saved: 2_000)  # 2%
        compressor = described_class.new(session_id: child[:id], config: config, db: db)
        expect(compressor.thrashing?).to be true
      end
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

    # #352: a SHORT id resolves the session row via #find (prefix match), but the
    # old compact! then looked up messages with `for_session(short_id)` — an
    # EXACT match — and got 0 rows, short-circuiting to no_op_result and a fake
    # "saved 0 tok" success. Resolving the short id to the FULL id before the
    # message lookup must compact the REAL transcript, not no-op.
    it "compacts the real session when given a SHORT id (#352)" do
      lineage_config = test_configuration(
        "compression" => Rubino::Config::Defaults.to_hash["compression"]
                                                 .merge("protect_first_n" => 1, "protect_last_n" => 1)
      )
      # These specs exercise the post-gate mechanics (lineage / short-id / atomic
      # rollback) on a few short messages that fall under the 64K compaction
      # floor, so force the budget gate true — the dedicated specs above cover
      # the below-threshold NO-OP itself.
      allow_any_instance_of(Rubino::Context::TokenBudget)
        .to receive(:needs_compaction?).and_return(true)
      15.times { |i| store.create(session_id: parent[:id], role: "user", content: "m#{i}") }

      allow(Rubino::Context::SummaryBuilder).to receive(:new).and_return(
        instance_double(Rubino::Context::SummaryBuilder, build: "NEW SUMMARY")
      )

      short_id = parent[:id][0, 8]
      result = described_class.new(session_id: short_id, config: lineage_config, db: db).compact!

      # Real compaction: NOT a 0-tok no-op, a child session was created, and the
      # source id was normalized to the full id (not left as the short prefix).
      expect(result[:skipped]).to be_nil
      expect(result[:saved_tokens]).to be > 0
      expect(result[:source_session_id]).to eq(parent[:id])
      expect(result[:target_session_id]).to be_truthy
    end
  end
end
