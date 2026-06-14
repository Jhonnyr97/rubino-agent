# frozen_string_literal: true

# r5 MF-4 / C-1: bare `chat` and `--continue` auto-resume must be SCOPED to the
# launching directory. Before this fix the resolver grabbed the globally-latest
# resumable session, so launching in folder B silently resumed folder A's
# conversation (and two tabs could stomp one session). These specs pin that the
# resolver now resolves the per-cwd latest, falling back to a FRESH session when
# this dir has none — rather than another folder's.
RSpec.describe Rubino::CLI::Chat::SessionResolver do
  let(:db)   { test_database }
  let(:repo) { Rubino::Session::Repository.new(db: db.db) }

  before do
    allow(Rubino).to receive(:database).and_return(db)
    Rubino.ui = Rubino::UI::Null.new
  end

  def seed_resumable(cwd)
    s = repo.create(source: "cli", cwd: cwd)
    repo.increment_message_count!(s[:id])
    s
  end

  describe "bare-chat auto-resume" do
    it "resumes THIS dir's session, not a newer one in another dir" do
      api = seed_resumable("/home/dev/api")
      seed_resumable("/home/dev/web") # newer, different dir
      allow(Rubino::Workspace).to receive(:primary_root).and_return("/home/dev/api")

      resolver = described_class.new({})
      expect(resolver.resolve_session_id(auto_resume: true)).to eq(api[:id])
    end

    it "starts FRESH (nil) in folder B instead of resuming folder A (MF-4 / C-1)" do
      seed_resumable("/home/dev/api") # only session, in /api
      allow(Rubino::Workspace).to receive(:primary_root).and_return("/home/dev/web")

      resolver = described_class.new({})
      expect(resolver.resolve_session_id(auto_resume: true)).to be_nil
      expect(resolver.auto_resumed_session).to be_nil
    end
  end

  describe "--continue" do
    it "continues THIS dir's latest, not the global latest" do
      api = seed_resumable("/home/dev/api")
      seed_resumable("/home/dev/web")
      allow(Rubino::Workspace).to receive(:primary_root).and_return("/home/dev/api")

      resolver = described_class.new({ continue: true })
      expect(resolver.resolve_session_id).to eq(api[:id])
    end

    it "warns + forks fresh when this dir has no session to continue" do
      seed_resumable("/home/dev/api")
      allow(Rubino::Workspace).to receive(:primary_root).and_return("/home/dev/web")

      resolver = described_class.new({ continue: true })
      expect(resolver.resolve_session_id).to be_nil
    end
  end

  describe "--resume <id> still overrides cwd scoping" do
    it "attaches to an explicit id regardless of the launch dir" do
      api = seed_resumable("/home/dev/api")
      allow(Rubino::Workspace).to receive(:primary_root).and_return("/home/dev/web")

      resolver = described_class.new({ resume: api[:id] })
      expect(resolver.resolve_session_id).to eq(api[:id])
    end
  end
end
