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
end
