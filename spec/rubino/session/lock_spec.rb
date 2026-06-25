# frozen_string_literal: true

# #543: per-session advisory cross-process lock. The pid-CAS in
# Repository#claim_for_resume! can't close the window BEFORE owner_pid is
# stamped, so two concurrent `--continue` both pick the same latest session and
# the loser forks a copy of a moving transcript. A real OS flock is atomic with
# no check-then-act window; these specs pin its single-holder semantics and the
# never-block degrade behaviour the resume path relies on.
RSpec.describe Rubino::Session::Lock do
  let(:home) { Dir.mktmpdir("rubino_lock_test") }

  after { FileUtils.remove_entry(home) if File.directory?(home) }

  describe ".try_acquire" do
    it "grants the lock to the first caller and refuses the second on the same id" do
      first = described_class.try_acquire("sess-1", home_path: home)
      expect(first).not_to be_nil

      # A SECOND open of the same session id (the concurrent-tab case) can't take
      # the exclusive flock — returns nil so the caller forks instead of stomping.
      second = described_class.try_acquire("sess-1", home_path: home)
      expect(second).to be_nil
    ensure
      first&.release
    end

    it "lets a DIFFERENT session id be locked independently" do
      a = described_class.try_acquire("sess-a", home_path: home)
      b = described_class.try_acquire("sess-b", home_path: home)
      expect(a).not_to be_nil
      expect(b).not_to be_nil
    ensure
      a&.release
      b&.release
    end

    it "re-grants the lock after the holder releases it" do
      first = described_class.try_acquire("sess-2", home_path: home)
      expect(first).not_to be_nil
      first.release

      second = described_class.try_acquire("sess-2", home_path: home)
      expect(second).not_to be_nil # free again
    ensure
      second&.release
    end

    it "treats a nil/blank id as a free no-op lock (unpersisted in-memory session)" do
      expect(described_class.try_acquire(nil, home_path: home)).not_to be_nil
      expect(described_class.try_acquire("", home_path: home)).not_to be_nil
    end

    it "creates the lock file under <home>/locks/" do
      lock = described_class.try_acquire("sess-3", home_path: home)
      expect(File.exist?(File.join(home, "locks", "session-sess-3.lock"))).to be(true)
    ensure
      lock&.release
    end
  end

  describe "#release" do
    it "is idempotent and safe to call when never acquired" do
      lock = described_class.new(File.join(home, "locks", "x.lock"))
      expect { lock.release }.not_to raise_error
    end
  end
end
