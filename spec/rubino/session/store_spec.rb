# frozen_string_literal: true

RSpec.describe Rubino::Session::Store do
  let(:db_connection) { test_database }
  let(:store)        { described_class.new(db: db_connection.db) }
  let(:session_repo) { Rubino::Session::Repository.new(db: db_connection.db) }
  let(:session)      { session_repo.create(source: "test") }

  before do
    db = db_connection.db
    db[:events].delete
    db[:tool_calls].delete
    db[:messages].delete
    db[:runs].delete if db.table_exists?(:runs)
    db[:sessions].delete
  end

  describe "#create" do
    it "creates and persists a message" do
      msg = store.create(session_id: session[:id], role: "user", content: "Hello world")
      expect(msg.id).not_to be_nil
      expect(msg.role).to eq("user")
      expect(msg.content).to eq("Hello world")
    end
  end

  describe "#for_session" do
    it "returns messages in chronological order" do
      store.create(session_id: session[:id], role: "user",      content: "first")
      store.create(session_id: session[:id], role: "assistant", content: "second")
      store.create(session_id: session[:id], role: "user",      content: "third")

      messages = store.for_session(session[:id])
      expect(messages.size).to eq(3)
      expect(messages.map(&:content)).to eq(%w[first second third])
    end

    # Regression: created_at is second-precision. Three rows inserted in the
    # same second (typical for "assistant preamble → tool result → assistant
    # follow-up" inside a single agent loop iteration) used to come back in
    # an undefined order, breaking the resumed transcript.
    it "breaks created_at ties on rowid to preserve insertion order" do
      same_ts = "2026-01-01T00:00:00Z"
      [
        ["assistant", "preamble"],
        ["tool",      "tool out"],
        ["assistant", "follow-up"]
      ].each do |role, content|
        db_connection.db[:messages].insert(
          id: SecureRandom.uuid,
          session_id: session[:id],
          role: role,
          content: content,
          created_at: same_ts
        )
      end

      messages = store.for_session(session[:id])
      expect(messages.map(&:content)).to eq(["preamble", "tool out", "follow-up"])
    end
  end

  describe "#count" do
    it "returns the correct message count" do
      store.create(session_id: session[:id], role: "user",      content: "a")
      store.create(session_id: session[:id], role: "assistant", content: "b")
      expect(store.count(session[:id])).to eq(2)
    end
  end

  describe "#recent" do
    it "returns the N most recent messages in order" do
      5.times { |i| store.create(session_id: session[:id], role: "user", content: "msg#{i}") }
      recent = store.recent(session[:id], count: 2)
      expect(recent.size).to eq(2)
      expect(recent.last.content).to eq("msg4")
    end

    it "returns all messages when count exceeds total" do
      store.create(session_id: session[:id], role: "user", content: "only")
      expect(store.recent(session[:id], count: 10).size).to eq(1)
    end
  end

  describe "#since (memory-extraction cursor, #249)" do
    it "returns all messages in order when the cursor is nil" do
      %w[a b c].each { |c| store.create(session_id: session[:id], role: "user", content: c) }
      expect(store.since(session[:id], after_id: nil).map(&:content)).to eq(%w[a b c])
    end

    it "returns only messages strictly newer than the cursor id" do
      a = store.create(session_id: session[:id], role: "user", content: "a")
      store.create(session_id: session[:id], role: "user", content: "b")
      store.create(session_id: session[:id], role: "user", content: "c")
      expect(store.since(session[:id], after_id: a.id).map(&:content)).to eq(%w[b c])
    end

    it "returns nothing when the cursor is already the newest message" do
      store.create(session_id: session[:id], role: "user", content: "a")
      last = store.create(session_id: session[:id], role: "user", content: "b")
      expect(store.since(session[:id], after_id: last.id)).to eq([])
    end

    it "splits same-second inserts on rowid (no overlap, no skip)" do
      same_ts = "2026-01-01T00:00:00Z"
      ids = %w[x y z].map do |c|
        id = SecureRandom.uuid
        db_connection.db[:messages].insert(id: id, session_id: session[:id],
                                           role: "user", content: c, created_at: same_ts)
        id
      end
      # Cursor at the middle row -> only the row after it (rowid tie-break).
      expect(store.since(session[:id], after_id: ids[1]).map(&:content)).to eq(%w[z])
    end

    # MEM-3: a message that arrives with an EARLIER created_at than the cursor
    # (backward clock step / NTP / VM suspend) must still be returned as "new" —
    # it was inserted after the cursor (higher rowid) even though its wall-clock
    # timestamp regressed. The old (created_at, rowid) tuple filter silently
    # dropped it forever; ordering on the monotonic rowid sees it.
    it "returns an out-of-order (backdated created_at) message newer than the cursor" do
      cursor = store.create(session_id: session[:id], role: "user", content: "ontime",
                            created_at: "2026-06-13T10:00:00+00:00")
      # Inserted AFTER the cursor but timestamped BEFORE it (clock went backwards).
      backdated = store.create(session_id: session[:id], role: "user", content: "skewed",
                               created_at: "2026-06-13T09:59:00+00:00")
      result = store.since(session[:id], after_id: cursor.id)
      expect(result.map(&:content)).to include("skewed")
      expect(result.map(&:id)).to eq([backdated.id])
    end
  end

  describe "#last_id" do
    it "returns the newest message id (rowid tie-break)" do
      store.create(session_id: session[:id], role: "user", content: "a")
      last = store.create(session_id: session[:id], role: "assistant", content: "b")
      expect(store.last_id(session[:id])).to eq(last.id)
    end

    it "is nil for an empty session" do
      expect(store.last_id(session[:id])).to be_nil
    end
  end

  describe "#seed_extraction_cursor (MEM-2)" do
    it "pins the watermark to the session's current last message" do
      store.create(session_id: session[:id], role: "user", content: "a")
      last = store.create(session_id: session[:id], role: "assistant", content: "b")
      seeded = store.seed_extraction_cursor(session[:id])
      expect(seeded).to eq(last.id)
      expect(db_connection.db[:sessions].where(id: session[:id]).get(:memory_extracted_msg_id))
        .to eq(last.id)
    end

    it "sets the cursor to nil for an empty session" do
      db_connection.db[:sessions].where(id: session[:id]).update(memory_extracted_msg_id: "stale")
      expect(store.seed_extraction_cursor(session[:id])).to be_nil
      expect(db_connection.db[:sessions].where(id: session[:id]).get(:memory_extracted_msg_id))
        .to be_nil
    end

    it "is a no-op when the session row is absent" do
      expect(store.seed_extraction_cursor("nonexistent")).to be_nil
    end
  end

  describe "#delete_from_inclusive (undo/retry rewind)" do
    it "deletes the message and everything after it" do
      store.create(session_id: session[:id], role: "user", content: "a")
      cut = store.create(session_id: session[:id], role: "user", content: "b")
      store.create(session_id: session[:id], role: "assistant", content: "c")
      removed = store.delete_from_inclusive(session[:id], from_id: cut.id)
      expect(removed).to eq(2)
      expect(store.for_session(session[:id]).map(&:content)).to eq(%w[a])
    end

    # MEM-1: undo/retry delete the cursor message; a dangling watermark made the
    # next extraction re-mine the whole remaining session (and could resurrect a
    # just-forgotten fact). The delete must re-seed the cursor to the new tail so
    # the next turn resumes from there, not from scratch.
    it "re-seeds the extraction cursor to the new tail after a delete" do
      store.create(session_id: session[:id], role: "user", content: "keep")
      cursor_msg = store.create(session_id: session[:id], role: "assistant", content: "old-cursor")
      db_connection.db[:sessions].where(id: session[:id])
                   .update(memory_extracted_msg_id: cursor_msg.id)
      # Delete the cursor message itself (what undo/retry do).
      store.delete_from_inclusive(session[:id], from_id: cursor_msg.id)
      new_cursor = db_connection.db[:sessions].where(id: session[:id]).get(:memory_extracted_msg_id)
      expect(new_cursor).to eq(store.last_id(session[:id]))
      expect(new_cursor).not_to eq(cursor_msg.id)
      # The remaining transcript is now entirely behind the cursor -> nothing
      # re-fed (no re-mine of the whole session).
      expect(store.since(session[:id], after_id: new_cursor)).to eq([])
    end

    it "clears the cursor when the delete empties the session" do
      first = store.create(session_id: session[:id], role: "user", content: "only")
      db_connection.db[:sessions].where(id: session[:id])
                   .update(memory_extracted_msg_id: first.id)
      store.delete_from_inclusive(session[:id], from_id: first.id)
      expect(db_connection.db[:sessions].where(id: session[:id]).get(:memory_extracted_msg_id))
        .to be_nil
    end
  end

  describe "#token_sum" do
    it "returns sum of token_count" do
      store.create(session_id: session[:id], role: "user", content: "hi", token_count: 5)
      store.create(session_id: session[:id], role: "assistant", content: "hello", token_count: 10)
      expect(store.token_sum(session[:id])).to eq(15)
    end

    it "returns 0 when no messages" do
      expect(store.token_sum(session[:id])).to eq(0)
    end
  end
end
