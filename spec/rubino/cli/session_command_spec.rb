# frozen_string_literal: true

# Regression guard for the `rubino sessions` verbs whose logic is SHARED with
# the in-chat /sessions verbs (#183): SessionCommand.render and
# SessionCommand.destroy_with_confirm are the single rendering / confirm-and-
# destroy flow for both surfaces, so the CLI behavior is pinned here and the
# in-chat behavior in spec/rubino/commands/executor_usability_spec.rb.
RSpec.describe Rubino::CLI::SessionCommand do
  let(:db)   { test_database }
  let(:ui)   { Rubino::UI::Null.new }
  let(:repo) { Rubino::Session::Repository.new(db: db.db) }

  before do
    allow(Rubino).to receive(:database).and_return(db)
    allow(Rubino).to receive(:ensure_database_ready!)
    Rubino.ui = ui
  end

  def info_lines
    ui.messages.select { |m| %i[info success].include?(m[:level]) }.map { |m| m[:message].to_s }
  end

  describe "#show" do
    it "renders the session details through the shared renderer" do
      repo.create(source: "cli", title: "inspect me")
      session = repo.list(limit: 1).first

      described_class.new.show(session[:id][0..7])

      joined = info_lines.join("\n")
      expect(joined).to include("Session: #{session[:id]}")
      expect(joined).to include("Title: inspect me")
      expect(joined).to include("Status: active")
    end

    it "raises a Thor::Error for an unknown id (no real exit)" do
      expect { described_class.new.show("zzz_nope") }
        .to raise_error(Thor::Error, /session not found/)
    end
  end

  describe "#delete" do
    it "destroys the session and its records after the confirm" do
      repo.create(source: "cli", title: "junk")
      session = repo.list(limit: 1).first
      allow(ui).to receive(:confirm).and_return(true)

      cmd = described_class.new
      cmd.options = { force: false }
      cmd.delete(session[:id])

      expect(repo.find(session[:id])).to be_nil
      expect(info_lines.join("\n")).to include("Deleted session #{session[:id][0..7]}")
    end

    it "aborts (and keeps the session) when the confirm is declined" do
      repo.create(source: "cli", title: "keep me")
      session = repo.list(limit: 1).first
      allow(ui).to receive(:confirm).and_return(false)

      cmd = described_class.new
      cmd.options = { force: false }
      cmd.delete(session[:id])

      expect(repo.find(session[:id])).not_to be_nil
      expect(info_lines.join("\n")).to include("Aborted.")
    end

    it "skips the confirm with --force" do
      repo.create(source: "cli", title: "forced")
      session = repo.list(limit: 1).first
      allow(ui).to receive(:confirm)

      cmd = described_class.new
      cmd.options = { force: true }
      cmd.delete(session[:id])

      expect(ui).not_to have_received(:confirm)
      expect(repo.find(session[:id])).to be_nil
    end
  end
end
