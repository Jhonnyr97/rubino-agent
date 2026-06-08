# frozen_string_literal: true

# #43: explicit --continue/-c must resume the latest RESUMABLE session
# (any status, message_count > 0), exactly like the bare-`chat` auto-resume —
# not the stricter latest_active, which silently forks a fresh session once the
# prior one is cleanly ended ("ended" status), losing context.
RSpec.describe Rubino::CLI::ChatCommand, "--continue resolves resumable" do
  let(:db) { test_database }
  let(:repo) { Rubino::Session::Repository.new(db: db.db) }

  before do
    allow(Rubino).to receive(:database).and_return(db)
  end

  def resolve(opts)
    described_class.new(opts).send(:resolve_session_id)
  end

  it "resumes the most recent cleanly-ended session (not a new one)" do
    session = repo.create(source: "cli", model: "gpt-4o")
    repo.increment_message_count!(session[:id]) # message_count > 0 ⇒ resumable
    repo.end_session!(session[:id])             # status = "ended"

    expect(repo.find(session[:id])[:status]).to eq("ended")
    expect(resolve(continue: true)).to eq(session[:id])
    expect(resolve(c: true)).to eq(session[:id])
  end

  it "returns nil (and does not fork onto an empty row) when nothing is resumable" do
    repo.create(source: "cli", model: "gpt-4o") # 0 messages ⇒ not resumable

    expect(resolve(continue: true)).to be_nil
  end
end
