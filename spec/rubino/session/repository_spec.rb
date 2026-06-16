# frozen_string_literal: true

RSpec.describe Rubino::Session::Repository do
  # Each example gets a fresh in-memory database
  let(:db_connection) { test_database }
  let(:repo) { described_class.new(db: db_connection.db) }

  before do
    db = db_connection.db
    db[:events].delete
    db[:tool_calls].delete
    db[:messages].delete
    db[:session_summaries].delete
    db[:runs].delete if db.table_exists?(:runs)
    db[:sessions].delete
  end

  describe "#create" do
    it "creates a session with default values" do
      session = repo.create(source: "cli", model: "gpt-4o")
      expect(session[:id]).not_to be_nil
      expect(session[:source]).to eq("cli")
      expect(session[:model]).to eq("gpt-4o")
      expect(session[:status]).to eq("active")
      expect(session[:message_count]).to eq(0)
    end
  end

  # #144: lazy session creation — build() makes an in-memory record with a
  # real id but no DB row; persist! inserts it on demand.
  describe "lazy creation (#build / #persist! / #persisted?)" do
    it "#build returns an unsaved record with a real id and no DB row" do
      session = repo.build(source: "cli", model: "gpt-4o")
      expect(session[:id]).not_to be_nil
      expect(session[:persisted]).to be(false)
      expect(repo.persisted?(session[:id])).to be(false)
      expect(repo.list).to be_empty
    end

    it "#persist! inserts the row and is idempotent" do
      session = repo.build(source: "cli", model: "gpt-4o", title: "later")
      repo.persist!(session)
      expect(repo.persisted?(session[:id])).to be(true)
      expect(session[:persisted]).to be(true)
      persisted = repo.find(session[:id])
      expect(persisted[:model]).to eq("gpt-4o")
      expect(persisted[:title]).to eq("later")

      # Idempotent: a second call neither raises nor double-inserts.
      expect { repo.persist!(session) }.not_to raise_error
      expect(repo.list.size).to eq(1)
    end

    it "#persisted? is false for an unknown id" do
      expect(repo.persisted?("does-not-exist")).to be(false)
      expect(repo.persisted?(nil)).to be(false)
    end
  end

  describe "#find" do
    it "finds a session by full ID" do
      session = repo.create(source: "cli")
      expect(repo.find(session[:id])[:id]).to eq(session[:id])
    end

    it "finds a session by prefix" do
      session = repo.create(source: "cli")
      expect(repo.find(session[:id][0..7])[:id]).to eq(session[:id])
    end

    it "returns nil for unknown ID" do
      expect(repo.find("nonexistent-id-00000000")).to be_nil
    end

    # #333a: the id prefix flowed straight into Sequel.like(:id, "#{q}%"), but
    # `%`/`_` are LIKE wildcards — so `find("%")` matched the FIRST of EVERY
    # session and `find("a_c")` treated `_` as any-char. The metacharacters must
    # be escaped so a bare wildcard query never resolves to an unrelated row.
    it "treats a lone % as a literal, not a match-all wildcard (#333a)" do
      repo.create(source: "cli")
      repo.create(source: "cli")
      expect(repo.find("%")).to be_nil
    end

    it "treats _ as a literal in an id prefix, not any-char (#333a)" do
      s = repo.create(source: "cli")
      # `_` would otherwise match the real id's first char positionally.
      expect(repo.find("_#{s[:id][1..7]}")).to be_nil
    end
  end

  describe "#find_by_id_or_title" do
    it "matches an exact ID" do
      s = repo.create(source: "cli")
      expect(repo.find_by_id_or_title(s[:id])[:id]).to eq(s[:id])
    end

    it "matches an ID prefix" do
      s = repo.create(source: "cli")
      expect(repo.find_by_id_or_title(s[:id][0..7])[:id]).to eq(s[:id])
    end

    it "falls back to a case-insensitive title substring" do
      s = repo.create(source: "cli", title: "Payments feature spike")
      expect(repo.find_by_id_or_title("payments")[:id]).to eq(s[:id])
    end

    # #103: a session auto-titled from its first user message must be
    # resolvable via --resume <title> — the title that auto-titling produces
    # is exactly the one resume looks up.
    it "matches a title produced by .derive_title (auto-title is resumable)" do
      title = described_class.derive_title("Add a modulo operation with tests")
      s = repo.create(source: "cli", title: title)
      expect(repo.find_by_id_or_title("modulo")[:id]).to eq(s[:id])
    end

    # #70: the stored title is truncated (~60 chars), so a word from the TAIL
    # of a long first prompt is not in the title at all. Resume must match
    # against the full first user message, not just the truncated title.
    it "matches a word from the truncated-away tail of the first user message" do
      prompt = "Please refactor the billing pipeline so invoices are " \
               "generated per tenant and emailed on schedule like four seasons"
      title  = described_class.derive_title(prompt)
      expect(title).not_to include("four seasons") # precondition: truncated away

      s = repo.create(source: "cli", title: title)
      Rubino::Session::Store.new(db: db_connection.db)
                            .create(session_id: s[:id], role: "user", content: prompt)

      expect(repo.find_by_id_or_title("four seasons")[:id]).to eq(s[:id])
    end

    it "matches the FIRST user message only, not later turns" do
      s = repo.create(source: "cli", title: "short title")
      store = Rubino::Session::Store.new(db: db_connection.db)
      store.create(session_id: s[:id], role: "user", content: "first prompt")
      store.create(session_id: s[:id], role: "user", content: "later xylophone prompt")

      expect(repo.find_by_id_or_title("xylophone")).to be_nil
    end

    it "returns nil when nothing matches" do
      expect(repo.find_by_id_or_title("absolutely-not-a-session")).to be_nil
    end

    it "returns nil for nil / empty input" do
      expect(repo.find_by_id_or_title(nil)).to be_nil
      expect(repo.find_by_id_or_title("")).to be_nil
    end

    # #333a: a `%` in the id-prefix branch must be a literal, not a match-all
    # wildcard that resolves `--resume "%"` to a random session (or raises
    # ambiguous across every row). With no title/message containing a literal
    # "%", it resolves to nothing.
    it "does not match every session for a lone % (#333a)" do
      repo.create(source: "cli", title: "alpha")
      repo.create(source: "cli", title: "beta")
      expect(repo.find_by_id_or_title("%")).to be_nil
    end

    # Regression: silently picking the first match meant --resume "feature"
    # could load either of two sessions titled "feature spike" / "feature
    # work" depending on creation order, with no warning. Same for short
    # ID prefixes that happen to collide. Now we raise with the candidates.
    context "ambiguous query" do
      it "raises with the candidates when an ID prefix matches more than one session" do
        # Two sessions whose IDs share a prefix are statistically rare with
        # full UUIDs but trivially collidable with a short prefix.
        allow(SecureRandom).to receive(:uuid).and_return(
          "abc11111-2222-3333-4444-555555555555",
          "abc22222-2222-3333-4444-666666666666"
        )
        repo.create(source: "cli", title: "a")
        repo.create(source: "cli", title: "b")
        allow(SecureRandom).to receive(:uuid).and_call_original

        expect { repo.find_by_id_or_title("abc") }
          .to raise_error(Rubino::AmbiguousSessionError) do |e|
            expect(e.matches.size).to eq(2)
          end
      end

      it "raises with the candidates when a title substring matches more than one session" do
        repo.create(source: "cli", title: "feature spike")
        repo.create(source: "cli", title: "feature tests")

        expect { repo.find_by_id_or_title("feature") }
          .to raise_error(Rubino::AmbiguousSessionError) do |e|
            expect(e.matches.size).to eq(2)
            expect(e.message).to include("Ambiguous")
            expect(e.message).to include("feature spike")
            expect(e.message).to include("feature tests")
          end
      end
    end
  end

  describe "#list" do
    it "returns sessions ordered by creation (newest first)" do
      repo.create(source: "cli", title: "first")
      repo.create(source: "cli", title: "second")
      sessions = repo.list
      expect(sessions.size).to eq(2)
      expect(sessions.first[:title]).to eq("second")
    end

    it "filters by status" do
      repo.create(source: "cli")
      ended = repo.create(source: "cli")
      repo.end_session!(ended[:id])

      expect(repo.list(status: "active").size).to eq(1)
      expect(repo.list(status: "ended").size).to eq(1)
    end

    # Item 2: internal subagent prompt-sessions (source="subagent", created by
    # the `task` tool) are machinery, not the user's conversations, so they are
    # hidden from the user-facing list/picker by default — but stay reachable by
    # explicit id (#find / #find_by_id_or_title never filter).
    describe "subagent session filtering (item 2)" do
      before do
        repo.create(source: "cli", title: "mine")
        @sub = repo.create(source: "subagent", title: "Use the shell tool to run exactly this")
      end

      it "excludes source=subagent sessions from the default list" do
        expect(repo.list.map { |s| s[:title] }).to eq(["mine"])
      end

      it "includes them when include_subagents: true (explicit opt-in)" do
        expect(repo.list(include_subagents: true).map { |s| s[:title] })
          .to contain_exactly("mine", "Use the shell tool to run exactly this")
      end

      it "keeps a subagent session resumable by explicit id (#find)" do
        expect(repo.find(@sub[:id])).not_to be_nil
        expect(repo.find_by_id_or_title(@sub[:id][0..7])).not_to be_nil
      end
    end

    # #334: a bare `sessions list` should default to THIS dir's sessions, so a
    # multi-folder user never sees another project's history. cwd: nil (--all)
    # restores the global listing.
    describe "cwd scoping (cwd:)" do
      before do
        repo.create(source: "cli", title: "in-a", cwd: "/home/dev/api")
        repo.create(source: "cli", title: "in-b", cwd: "/home/dev/web")
      end

      it "lists only sessions stamped to the given cwd" do
        titles = repo.list(cwd: "/home/dev/api").map { |s| s[:title] }
        expect(titles).to eq(%w[in-a])
      end

      it "lists every dir when cwd is nil (the --all path)" do
        expect(repo.list(cwd: nil).map { |s| s[:title] }).to contain_exactly("in-a", "in-b")
      end

      it "matches through a symlinked/relative cwd via canonical paths" do
        repo.create(source: "cli", title: "here", cwd: Dir.pwd)
        titles = repo.list(cwd: File.join(Dir.pwd, ".")).map { |s| s[:title] }
        expect(titles).to include("here")
      end
    end
  end

  describe "#increment_message_count!" do
    it "increments the count" do
      session = repo.create(source: "cli")
      repo.increment_message_count!(session[:id])
      repo.increment_message_count!(session[:id])
      expect(repo.find(session[:id])[:message_count]).to eq(2)
    end
  end

  describe "#end_session!" do
    it "marks session as ended with timestamp" do
      session = repo.create(source: "cli")
      repo.end_session!(session[:id])
      updated = repo.find(session[:id])
      expect(updated[:status]).to eq("ended")
      expect(updated[:ended_at]).not_to be_nil
    end
  end

  # #11: a hard kill (SIGKILL) / closed terminal can leave a session "active"
  # with its owning process gone. The reaper stamps ended_at on next list/resume.
  describe "#reap_orphaned_active!" do
    it "ends an active session whose owning process is dead" do
      session = repo.create(source: "cli")
      # Forge a dead owner: kill -0 against a guaranteed-free pid raises ESRCH.
      dead_pid = unused_pid
      db_connection.db[:sessions].where(id: session[:id]).update(owner_pid: dead_pid)

      reaped = repo.reap_orphaned_active!

      expect(reaped).to eq(1)
      ended = repo.find(session[:id])
      expect(ended[:status]).to eq("ended")
      expect(ended[:ended_at]).not_to be_nil
    end

    it "leaves a session owned by a live process (this one) untouched" do
      session = repo.create(source: "cli") # create stamps owner_pid = Process.pid
      expect(repo.reap_orphaned_active!).to eq(0)
      expect(repo.find(session[:id])[:status]).to eq("active")
    end

    it "leaves a session with no recorded pid untouched" do
      session = repo.create(source: "cli")
      db_connection.db[:sessions].where(id: session[:id]).update(owner_pid: nil)
      expect(repo.reap_orphaned_active!).to eq(0)
      expect(repo.find(session[:id])[:status]).to eq("active")
    end

    # Returns the lowest pid not currently in use, so kill(0) raises ESRCH.
    def unused_pid
      pid = 999_999
      pid -= 1 while pid > 1 && process_present?(pid)
      pid
    end

    def process_present?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
  end

  describe "#latest_active" do
    it "returns the most recently updated active session" do
      repo.create(source: "cli")
      second = repo.create(source: "cli")
      expect(repo.latest_active[:id]).to eq(second[:id])
    end

    it "returns nil when no active sessions" do
      s = repo.create(source: "cli")
      repo.end_session!(s[:id])
      expect(repo.latest_active).to be_nil
    end
  end

  describe "#latest_resumable" do
    it "returns the most recent session that has messages" do
      old = repo.create(source: "cli")
      repo.increment_message_count!(old[:id])
      recent = repo.create(source: "cli")
      repo.increment_message_count!(recent[:id])
      expect(repo.latest_resumable[:id]).to eq(recent[:id])
    end

    it "skips empty (0-message) sessions so they never shadow real work" do
      with_msgs = repo.create(source: "cli")
      repo.increment_message_count!(with_msgs[:id])
      repo.create(source: "cli") # newer but empty
      expect(repo.latest_resumable[:id]).to eq(with_msgs[:id])
    end

    it "resumes an ended session too (a closed terminal still continues)" do
      s = repo.create(source: "cli")
      repo.increment_message_count!(s[:id])
      repo.end_session!(s[:id])
      expect(repo.latest_resumable[:id]).to eq(s[:id])
    end

    it "returns nil on a true first run (no sessions with messages)" do
      repo.create(source: "cli")
      expect(repo.latest_resumable).to be_nil
    end

    # #394: a freshly-compacted child (source="compaction") carries a fully
    # copied transcript but its cached message_count may still be 0 in the window
    # before the Compressor syncs it (or if the process exits right after the
    # copy). It must still be resumable via `--continue`, or the just-compacted
    # arc is silently skipped and lost.
    it "resumes a compaction child even when its cached message_count is 0" do
      child = repo.create(source: "compaction") # message_count defaults to 0
      expect(child[:message_count]).to eq(0)
      expect(repo.latest_resumable[:id]).to eq(child[:id])
      # ...while a 0-message NON-compaction session is still skipped (the
      # "returns nil on a true first run" case above covers the cli source).
    end
  end

  # r5 MF-4 / C-1: every session is stamped with the dir it was launched in so
  # resume can be scoped per-cwd, killing "folder B silently resumes folder A".
  describe "cwd stamping" do
    it "#create stamps an explicit cwd and #find returns it" do
      s = repo.create(source: "cli", cwd: "/home/dev/api")
      expect(s[:cwd]).to eq("/home/dev/api")
      expect(repo.find(s[:id])[:cwd]).to eq("/home/dev/api")
    end

    it "#create defaults cwd to the workspace primary root when not given" do
      allow(Rubino::Workspace).to receive(:primary_root).and_return("/home/dev/web")
      s = repo.create(source: "cli")
      expect(repo.find(s[:id])[:cwd]).to eq("/home/dev/web")
    end

    it "#build carries a cwd that #persist! writes through to the row" do
      built = repo.build(source: "cli", cwd: "/home/dev/scripts")
      expect(built[:cwd]).to eq("/home/dev/scripts")
      repo.persist!(built)
      expect(repo.find(built[:id])[:cwd]).to eq("/home/dev/scripts")
    end
  end

  describe "#latest_resumable_for_cwd" do
    def resumable_in(dir)
      s = repo.create(source: "cli", cwd: dir)
      repo.increment_message_count!(s[:id])
      s
    end

    it "resumes the latest session FOR THIS dir, never a newer one in another dir" do
      api = resumable_in("/home/dev/api")
      resumable_in("/home/dev/web") # newer, different dir
      expect(repo.latest_resumable_for_cwd("/home/dev/api")[:id]).to eq(api[:id])
    end

    it "does NOT resume folder A's session when launched in folder B (MF-4 / C-1)" do
      resumable_in("/home/dev/api") # only session exists, in /api
      # A bare chat in /web must start fresh, not latch onto /api.
      expect(repo.latest_resumable_for_cwd("/home/dev/web")).to be_nil
      # ...whereas the global latest_resumable WOULD have grabbed /api (the bug).
      expect(repo.latest_resumable[:cwd]).to eq("/home/dev/api")
    end

    it "two different dirs each resolve to their OWN latest (no cross-stomp)" do
      api = resumable_in("/home/dev/api")
      web = resumable_in("/home/dev/web")
      expect(repo.latest_resumable_for_cwd("/home/dev/api")[:id]).to eq(api[:id])
      expect(repo.latest_resumable_for_cwd("/home/dev/web")[:id]).to eq(web[:id])
    end

    it "matches through symlinks/non-canonical paths (realpath compare)" do
      s = resumable_in(Dir.pwd)
      # A trailing-dot / "./" form of the same dir still resolves.
      expect(repo.latest_resumable_for_cwd(File.join(Dir.pwd, "."))[:id]).to eq(s[:id])
    end

    it "skips a session a DIFFERENT live process is actively writing (no two-tab stomp)" do
      s = resumable_in("/home/dev/api")
      # Simulate another live tab owning this active session.
      repo.update(s[:id], status: "active", owner_pid: 999_999)
      allow(repo).to receive(:process_alive?).and_call_original
      allow(repo).to receive(:process_alive?).with(999_999).and_return(true)
      expect(repo.latest_resumable_for_cwd("/home/dev/api")).to be_nil
    end

    it "still resumes a session owned by our OWN pid (same tab reopening)" do
      s = repo.create(source: "cli", cwd: "/home/dev/api") # owner_pid = our pid
      repo.increment_message_count!(s[:id])
      expect(repo.latest_resumable_for_cwd("/home/dev/api")[:id]).to eq(s[:id])
    end

    it "resumes a session whose owner is DEAD (a crashed prior tab)" do
      s = resumable_in("/home/dev/api")
      repo.update(s[:id], status: "active", owner_pid: 999_999)
      allow(repo).to receive(:process_alive?).and_call_original
      allow(repo).to receive(:process_alive?).with(999_999).and_return(false)
      expect(repo.latest_resumable_for_cwd("/home/dev/api")[:id]).to eq(s[:id])
    end

    it "ignores pre-cwd-column sessions (NULL cwd never matches a dir)" do
      s = repo.create(source: "cli", cwd: nil)
      repo.increment_message_count!(s[:id])
      expect(repo.latest_resumable_for_cwd("/home/dev/api")).to be_nil
    end

    it "returns nil when no session has messages in this dir" do
      repo.create(source: "cli", cwd: "/home/dev/api") # 0 messages
      expect(repo.latest_resumable_for_cwd("/home/dev/api")).to be_nil
    end

    # #394: `--continue` (this method) must resume a freshly-compacted child in
    # THIS dir even before its cached message_count is synced.
    it "resumes a 0-count compaction child scoped to this dir" do
      child = repo.create(source: "compaction", cwd: "/home/dev/api")
      expect(child[:message_count]).to eq(0)
      expect(repo.latest_resumable_for_cwd("/home/dev/api")[:id]).to eq(child[:id])
    end
  end

  # #347: the explicit-resume owner-guard reuses the SAME live-owner predicate
  # auto-resume relies on, now exposed publicly so the Runner can consult it.
  describe "#owned_by_other_live_process?" do
    it "is true for an active session a DIFFERENT live process owns" do
      s = repo.create(source: "cli")
      repo.update(s[:id], status: "active", owner_pid: 999_999)
      allow(repo).to receive(:process_alive?).and_call_original
      allow(repo).to receive(:process_alive?).with(999_999).and_return(true)
      expect(repo.owned_by_other_live_process?(repo.find(s[:id]))).to be true
    end

    it "is false for our OWN pid, a dead owner, or no pid" do
      ours = repo.create(source: "cli") # owner_pid = our pid
      expect(repo.owned_by_other_live_process?(repo.find(ours[:id]))).to be false

      dead = repo.create(source: "cli")
      repo.update(dead[:id], status: "active", owner_pid: 999_999)
      allow(repo).to receive(:process_alive?).and_call_original
      allow(repo).to receive(:process_alive?).with(999_999).and_return(false)
      expect(repo.owned_by_other_live_process?(repo.find(dead[:id]))).to be false
    end

    # #376 (residual #347): the owner-guard must fire on an ENDED session a
    # DIFFERENT live process is re-writing, not just on status="active". A
    # finished turn leaves status="ended" while the resuming process still claims
    # owner_pid; two concurrent explicit resumes of that row would otherwise race
    # unguarded and interleave writes into one malformed transcript.
    it "is true for an ENDED session a DIFFERENT live process still owns (#376)" do
      ended = repo.create(source: "cli")
      repo.update(ended[:id], status: "ended", owner_pid: 999_999)
      allow(repo).to receive(:process_alive?).and_call_original
      allow(repo).to receive(:process_alive?).with(999_999).and_return(true)
      expect(repo.owned_by_other_live_process?(repo.find(ended[:id]))).to be true
    end
  end

  # #390 (residual #376) — the explicit-resume owner-claim must be ATOMIC. The
  # old runner did a check-then-stamp: owned_by_other_live_process? READ
  # owner_pid, then a LATER update(id, owner_pid:) STAMPED it. Two concurrent
  # `chat --resume <id>` both read the SAME dead owner_pid, both passed the
  # check, and both stamped+wrote the row → user,user interleave. claim_for_resume!
  # folds the read and the stamp into one compare-and-swap (Jobs::Queue#claim!
  # idiom): exactly one racer wins, the loser gets false and forks.
  describe "#claim_for_resume! (atomic owner-claim)" do
    it "exactly ONE of two racers on the SAME dead-owner row wins the claim" do
      s = repo.create(source: "cli")
      dead = 999_999
      repo.update(s[:id], status: "ended", owner_pid: dead) # owner gone (process dead)

      # Both racers observe the same dead owner_pid (process_alive?(dead) == false
      # so live_owned_by_other? is false → both are eligible to attempt the CAS).
      allow(repo).to receive(:process_alive?).and_call_original
      allow(repo).to receive(:process_alive?).with(dead).and_return(false)

      row_a = repo.find(s[:id]) # racer A's view (owner_pid: dead)
      row_b = repo.find(s[:id]) # racer B's view (owner_pid: dead, the SAME stale read)

      won_a = repo.claim_for_resume!(row_a)
      won_b = repo.claim_for_resume!(row_b)

      # ATOMIC: the first CAS rewrites owner_pid to our live pid; the second's
      # WHERE owner_pid = <dead> no longer matches → rowcount 0 → loses the race.
      expect([won_a, won_b]).to contain_exactly(true, false)
      # The winner left the row stamped to THIS process — never the dead owner.
      expect(repo.find(s[:id])[:owner_pid]).to eq(Process.pid)
    end

    it "claims an UNOWNED (nil owner_pid) row and rejects a duplicate racer" do
      s = repo.create(source: "cli")
      repo.update(s[:id], status: "ended", owner_pid: nil)

      row_a = repo.find(s[:id])
      row_b = repo.find(s[:id])
      expect(repo.claim_for_resume!(row_a)).to be true
      # Second racer still reads owner_pid: nil but the CAS on `owner_pid IS NULL`
      # now misses (we stamped our pid), so it loses and the caller forks.
      expect(repo.claim_for_resume!(row_b)).to be false
    end

    it "refuses (forks) when a DIFFERENT live process owns the row — never stomps" do
      s = repo.create(source: "cli")
      repo.update(s[:id], status: "active", owner_pid: 999_999)
      allow(repo).to receive(:process_alive?).and_call_original
      allow(repo).to receive(:process_alive?).with(999_999).and_return(true)

      expect(repo.claim_for_resume!(repo.find(s[:id]))).to be false
      # The live foreign owner is left untouched (no stamp), so the resumer forks.
      expect(repo.find(s[:id])[:owner_pid]).to eq(999_999)
    end

    it "is a no-op-success for a row we ALREADY own (our own pid)" do
      ours = repo.create(source: "cli") # owner_pid = our pid
      expect(repo.claim_for_resume!(repo.find(ours[:id]))).to be true
      expect(repo.find(ours[:id])[:owner_pid]).to eq(Process.pid)
    end
  end

  describe ".derive_title" do
    it "derives a clean one-line title from the first user message" do
      expect(described_class.derive_title("Add a modulo operation")).to eq("Add a modulo operation")
    end

    it "collapses whitespace and uses only the first line" do
      expect(described_class.derive_title("  fix\tthe   bug\nand more")).to eq("fix the bug")
    end

    it "strips a leading slash command" do
      expect(described_class.derive_title("/review the auth change")).to eq("the auth change")
    end

    it "truncates long messages on a word boundary with an ellipsis" do
      long = "please add a fully tested modulo operation to the calculator gem with edge cases"
      title = described_class.derive_title(long, max: 30)
      expect(title.length).to be <= 31
      expect(title).to end_with("…")
      # Broke on a word boundary: the text before the ellipsis is a run of
      # whole words from the source, not a word sliced in half.
      body = title.delete_suffix("…")
      expect(long).to start_with(body)
      expect(long[body.length]).to eq(" ") # next source char is a space, i.e. we cut between words
    end

    it "returns nil for blank input" do
      expect(described_class.derive_title("   ")).to be_nil
      expect(described_class.derive_title(nil)).to be_nil
    end

    # #128: a throwaway sub-3-char first prompt ("y" the user immediately
    # interrupted) must not become the title — the resume hint would suggest a
    # useless one-char matcher (`--resume "y"`). The session stays untitled so
    # the next meaningful prompt titles it instead.
    it "returns nil for junk-short input so the next real prompt titles the session (#128)" do
      expect(described_class.derive_title("y")).to be_nil
      expect(described_class.derive_title("ok")).to be_nil
      expect(described_class.derive_title("fix")).to eq("fix") # 3 chars is meaningful enough
    end

    it "treats a slash command with a junk-short remainder as junk too (#128)" do
      expect(described_class.derive_title("/mode y")).to be_nil
    end
  end

  # #374 — destroying a session deleted only DB rows, leaving its on-disk
  # spill (tool-results/<call_id>.txt) and paste (sessions/<id>/paste_N.txt)
  # files orphaned forever.
  describe "#destroy! removes spill/paste files (#374)" do
    let(:home) { Dir.mktmpdir("repo_destroy_files") }

    before { allow(Rubino).to receive(:home_path).and_return(home) }
    after  { FileUtils.rm_rf(home) }

    it "deletes the session's paste subtree and spill files keyed by its call ids" do
      db = db_connection.db
      session = repo.create(source: "cli")
      db[:tool_calls].insert(id: "callX", session_id: session[:id], tool_name: "shell",
                             status: "completed", started_at: "t", finished_at: "t")

      paste_dir = File.join(home, "sessions", session[:id])
      FileUtils.mkdir_p(paste_dir)
      paste = File.join(paste_dir, "paste_1.txt")
      File.write(paste, "big paste")
      spill_dir = File.join(home, "tool-results")
      FileUtils.mkdir_p(spill_dir)
      spill = File.join(spill_dir, "callX.txt")
      File.write(spill, "big output")

      repo.destroy!(session[:id])

      expect(File).not_to exist(paste)
      expect(File).not_to exist(paste_dir)
      expect(File).not_to exist(spill)
      # And the DB rows are gone too (existing behavior intact).
      expect(repo.find(session[:id])).to be_nil
      expect(db[:tool_calls].where(session_id: session[:id]).count).to eq(0)
    end
  end
end
