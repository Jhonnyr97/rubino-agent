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
      allow(ui).to receive(:confirm_destructive).and_return(true)

      cmd = described_class.new
      cmd.options = { force: false }
      cmd.delete(session[:id])

      expect(repo.find(session[:id])).to be_nil
      expect(info_lines.join("\n")).to include("Deleted session #{session[:id][0..7]}")
    end

    it "aborts (and keeps the session) when the confirm is declined" do
      repo.create(source: "cli", title: "keep me")
      session = repo.list(limit: 1).first
      allow(ui).to receive(:confirm_destructive).and_return(false)

      cmd = described_class.new
      cmd.options = { force: false }
      cmd.delete(session[:id])

      expect(repo.find(session[:id])).not_to be_nil
      expect(info_lines.join("\n")).to include("Aborted.")
    end

    # #218: a non-interactive / piped / EOF answer must DEFAULT to No and must
    # NOT delete. UI::Null#confirm_destructive fails closed (false), modelling the
    # piped `echo n | rubino sessions delete` path — the session must survive.
    it "keeps the session on a non-interactive (fail-closed) confirm" do
      repo.create(source: "cli", title: "data loss guard")
      session = repo.list(limit: 1).first

      cmd = described_class.new
      cmd.options = { force: false }
      cmd.delete(session[:id])

      expect(repo.find(session[:id])).not_to be_nil
      expect(info_lines.join("\n")).to include("Aborted.")
    end

    # #218: a destructive confirm must never reuse the tool-approval menu.
    it "uses the destructive yes/No confirm, never the tool-approval prompt" do
      repo.create(source: "cli", title: "no approval menu")
      session = repo.list(limit: 1).first
      allow(ui).to receive(:confirm_destructive).and_return(true)
      allow(ui).to receive(:confirm)

      cmd = described_class.new
      cmd.options = { force: false }
      cmd.delete(session[:id])

      expect(ui).to have_received(:confirm_destructive)
      expect(ui).not_to have_received(:confirm)
    end

    it "skips the confirm with --force" do
      repo.create(source: "cli", title: "forced")
      session = repo.list(limit: 1).first
      allow(ui).to receive(:confirm_destructive)

      cmd = described_class.new
      cmd.options = { force: true }
      cmd.delete(session[:id])

      expect(ui).not_to have_received(:confirm_destructive)
      expect(repo.find(session[:id])).to be_nil
    end
  end

  # R4-N2 — a session title is generated from the conversation, so it is
  # attacker-influenceable. The shared renderer prints it through `info`, which
  # does NOT sanitize, so a raw OSC/CSI in the title would hijack the window
  # title / clear the screen. The renderer now neutralizes the field to caret
  # notation before it reaches the printer.
  describe "#render neutralizes terminal escapes in untrusted title (R4-N2)" do
    it "renders a clear-screen + title-hijack title as caret text" do
      session = { id: "deadbeefcafef00d", title: "\e[2J\e]0;HIJACKED\aevil",
                  status: "active", model: "m", message_count: 1, token_count: 2,
                  created_at: "2026-06-14", updated_at: "2026-06-14" }
      described_class.render(session, ui: ui)

      title_line = info_lines.find { |l| l.start_with?("Title:") }
      expect(title_line).not_to include("\e[2J")
      expect(title_line).not_to include("\e]0;")
      expect(title_line).to include("HIJACKED") # payload survives as caret text
      expect(title_line).to include("^[")
    end
  end

  # r5 MF-4: `sessions list` / `show` must expose each session's launch dir so a
  # multi-folder user can tell which project a session belongs to.
  describe "cwd in the listing (r5 MF-4)" do
    def table_rows
      msg = ui.messages.find { |m| m[:level] == :table }
      msg && msg[:message]
    end

    it "#list includes a Dir column with each session's cwd" do
      repo.create(source: "cli", title: "api work", cwd: "/home/dev/api")
      repo.create(source: "cli", title: "web work", cwd: "/home/dev/web")

      cmd = described_class.new
      cmd.options = { limit: 20 }
      cmd.list

      table = table_rows
      expect(table[:headers]).to include("Dir")
      dir_idx = table[:headers].index("Dir")
      dirs = table[:rows].map { |r| r[dir_idx] }
      expect(dirs).to include("/home/dev/api", "/home/dev/web")
    end

    it "#show renders the session's Dir" do
      repo.create(source: "cli", title: "inspect", cwd: "/home/dev/scripts")
      session = repo.list(limit: 1).first
      described_class.new.show(session[:id][0..7])
      expect(info_lines.join("\n")).to include("Dir: /home/dev/scripts")
    end

    it "shows a dash for a pre-cwd-column (NULL cwd) session" do
      repo.create(source: "cli", title: "legacy", cwd: nil)
      session = repo.list(limit: 1).first
      described_class.new.show(session[:id][0..7])
      expect(info_lines.join("\n")).to include("Dir: —")
    end
  end

  # HIGH-2: a corrupt/malformed DB used to dump a raw ~20-line Sequel/sqlite3
  # backtrace from `sessions list`. The guard turns it into a clean, actionable
  # Thor::Error (printed to stderr, no backtrace) pointing at `rubino setup`.
  describe "corrupt-database guard" do
    let(:corrupt_dir)  { Dir.mktmpdir("ra-sess-corrupt") }
    let(:corrupt_path) { File.join(corrupt_dir, "rubino.sqlite3") }

    after { FileUtils.remove_entry(corrupt_dir) }

    before do
      seed = Rubino::Database::Connection.new(corrupt_path)
      seed.db.run("CREATE TABLE t (a integer, b text)")
      300.times { |i| seed.db.run("INSERT INTO t VALUES (#{i}, '#{"x" * 200}')") }
      seed.close
      File.truncate(corrupt_path, 20_000)
      allow(Rubino).to receive(:database)
        .and_return(Rubino::Database::Connection.new(corrupt_path))
    end

    it "#list raises a clean Thor::Error (no raw sqlite backtrace)" do
      cmd = described_class.new
      cmd.options = { limit: 20 }
      expect { cmd.list }.to raise_error(Thor::Error, /corrupt.*rubino setup/m)
    end

    it "#show also degrades to the clean diagnostic" do
      expect { described_class.new.show("anything") }
        .to raise_error(Thor::Error, /corrupt/i)
    end
  end
end
