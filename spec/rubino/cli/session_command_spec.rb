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

    # #382 — the Messages/Tokens lines must reflect the REAL cumulative state,
    # not the drifting cached sessions.message_count column (which counts only
    # top-level turns and hides every assistant(tool_use)/tool(result) row) nor a
    # non-cumulative token count. Seed a session whose actual messages include
    # tool rows and assert the count includes them (with a tool label) and the
    # token total is the SUM over all messages.
    describe "Messages/Tokens reflect the real cumulative state (#382)" do
      it "counts tool messages (labeled) and sums all token counts" do
        repo.create(source: "cli", title: "tool-heavy")
        session = repo.list(limit: 1).first
        # The cached column lies — set it to a misleading low number on purpose.
        db.db[:sessions].where(id: session[:id]).update(message_count: 2, token_count: 5)

        store = Rubino::Session::Store.new(db: db.db)
        store.create(session_id: session[:id], role: "user", content: "do it", token_count: 10)
        store.create(session_id: session[:id], role: "assistant", content: "calling tool", token_count: 20)
        store.create(session_id: session[:id], role: "tool", content: "tool out", tool_name: "read", token_count: 30)
        store.create(session_id: session[:id], role: "assistant", content: "the answer", token_count: 40)

        described_class.new.show(session[:id][0..7])
        joined = info_lines.join("\n")

        # 4 real messages, 1 of them a tool row — the cached "2" is ignored.
        expect(joined).to include("Messages: 4 (1 tool)")
        # Cumulative token sum 10+20+30+40 = 100, not the cached 5.
        expect(joined).to include("Tokens: 100")
      end

      it "omits the tool label when there are no tool messages" do
        repo.create(source: "cli", title: "no tools")
        session = repo.list(limit: 1).first
        store = Rubino::Session::Store.new(db: db.db)
        store.create(session_id: session[:id], role: "user", content: "hi", token_count: 3)
        store.create(session_id: session[:id], role: "assistant", content: "hello", token_count: 4)

        described_class.new.show(session[:id][0..7])
        joined = info_lines.join("\n")
        expect(joined).to match(/Messages: 2$/)
        expect(joined).not_to include("tool)")
      end
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
      # These sessions belong to OTHER dirs; --all opts out of the new #334
      # current-dir default so the Dir column can be asserted across dirs.
      cmd.options = { limit: 20, all: true }
      cmd.list

      table = table_rows
      expect(table[:headers]).to include("Dir")
      dir_idx = table[:headers].index("Dir")
      dirs = table[:rows].map { |r| r[dir_idx] }
      expect(dirs).to include("/home/dev/api", "/home/dev/web")
    end

    # #334: a bare `sessions list` defaults to THIS dir's sessions; --all opts
    # back into the global listing.
    it "#list defaults to the current dir and hides other dirs' sessions" do
      repo.create(source: "cli", title: "here", cwd: Rubino::Workspace.primary_root)
      repo.create(source: "cli", title: "elsewhere", cwd: "/home/dev/elsewhere")

      cmd = described_class.new
      cmd.options = { limit: 20 } # no --all
      cmd.list

      titles = table_rows[:rows].map { |r| r[1] }
      expect(titles).to include("here")
      expect(titles).not_to include("elsewhere")
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

  # #352: `sessions compact <short-id>` used to resolve the row via #find but
  # then hand the SHORT id to the Compressor, whose `for_session(short_id)`
  # (exact match) returned 0 messages — a silent no-op the CLI dressed up as
  # "┄ compacted · saved 0 tok ┄". The command must (a) feed the Compressor the
  # FULL resolved id and (b) never report a no-op as success.
  describe "#compact (#352)" do
    it "passes the FULL resolved id to the Compressor, not the short prefix" do
      repo.create(source: "cli", title: "to compact")
      session = repo.list(limit: 1).first
      short   = session[:id][0, 8]

      captured = nil
      fake = instance_double(Rubino::Context::Compressor,
                             compact!: { source_session_id: session[:id], saved_tokens: 7,
                                         target_session_id: "child" })
      allow(Rubino::Context::Compressor).to receive(:new) do |session_id:|
        captured = session_id
        fake
      end

      described_class.new.compact(short)
      expect(captured).to eq(session[:id])
    end

    # Item 4: `sessions compact` reports the before→after token savings (and the
    # message-count change), consistent with the interactive `/compact`.
    it "reports the before→after token savings and message counts (item 4)" do
      repo.create(source: "cli", title: "savings")
      session = repo.list(limit: 1).first

      fake = instance_double(
        Rubino::Context::Compressor,
        compact!: { source_session_id: session[:id], saved_tokens: 99,
                    target_session_id: session[:id], original_messages: 20,
                    compacted_messages: 6 }
      )
      allow(Rubino::Context::Compressor).to receive(:new).and_return(fake)

      described_class.new.compact(session[:id][0, 8])
      line = info_lines.find { |l| l.include?("Context:") }
      expect(line).to match(/Context: ~\d+ → ~\d+ tokens \(.*tok; 20 → 6 messages\)\./)
      # The compression_finished metadata carries the TRUTHFUL before→after delta
      # (saved_tokens), not the compressor's removed-middle estimate.
      finished = ui.messages.find { |m| m[:level] == :compression_finished }
      expect(finished[:message][:saved_tokens]).to be_a(Integer)
    end

    # #500: a no-op on a session with PLENTY of messages but under the token
    # budget returns reason: :below_threshold — the CLI must explain THAT, not
    # the catch-all "too few messages to summarize" it printed for every skip.
    it "prints the below-threshold reason, not 'too few messages', for a :below_threshold no-op" do
      repo.create(source: "cli", title: "below threshold")
      session = repo.list(limit: 1).first

      fake = instance_double(
        Rubino::Context::Compressor,
        compact!: { source_session_id: session[:id], saved_tokens: 0, skipped: true,
                    reason: :below_threshold, minimum_messages: 28 }
      )
      allow(Rubino::Context::Compressor).to receive(:new).and_return(fake)

      expect { described_class.new.compact(session[:id][0, 8]) }
        .to raise_error(Thor::Error) { |e|
          expect(e.message).to match(/below the compaction threshold/i)
          expect(e.message).not_to match(/too few messages/i)
        }
    end
  end

  # Item 3: bare `rubino sessions` LISTS (off a TTY) rather than printing the
  # subcommand-help roster — listing is the common intent. Thor's
  # default_command points at #browse, which routes a non-TTY invocation to
  # #list. (The on-a-TTY picker is covered in the resume-picker block above.)
  describe "bare invocation lists (item 3)" do
    it "browse is Thor's default_command for bare `rubino sessions`" do
      expect(described_class.default_command).to eq("browse")
    end

    it "renders the session table when invoked bare off a TTY (browse → list)" do
      repo.create(source: "cli", title: "listed-by-default")
      # Unscope the cwd filter so the seeded session lists regardless of test cwd.
      allow(Rubino::Workspace).to receive(:primary_root).and_return(nil)
      allow($stdout).to receive(:tty?).and_return(false)

      cmd = described_class.new
      cmd.options = { limit: 20, all: false }
      cmd.browse

      table = ui.messages.find { |m| m[:level] == :table }
      expect(table).not_to be_nil
      titles = table[:message][:rows].map { |r| r[1].to_s }
      expect(titles).to include("listed-by-default")
    end

    it "errors clearly on a no-op instead of a fake 'saved 0 tok' success" do
      repo.create(source: "cli", title: "too short")
      session = repo.list(limit: 1).first

      # A real session with too few messages compacts to a skipped no-op.
      expect { described_class.new.compact(session[:id][0, 8]) }
        .to raise_error(Thor::Error, /nothing to compact/i)
      # And it must NOT have printed the fake-success token line.
      expect(ui.messages.map { |m| m[:level] }).not_to include(:compression_finished)
    end
  end

  # CLI resume picker: bare `rubino sessions` on a TTY opens the SAME arrow-key
  # picker the in-REPL `/sessions` uses (Session::Picker), and on Enter boots
  # the chat REPL resumed at the chosen id via the EXACT path
  # `rubino chat --session <id>` runs (ChatCommand). Off a TTY it stays the
  # script-safe `list` table; `sessions list` (explicit) is always the table.
  describe "bare `sessions` resume picker (CLI)" do
    # `resume`/`list`/`browse` build a fresh Session::Repository (no db: kwarg)
    # ⇒ they read Rubino.database, which the outer `before` already stubs.

    # Drives the bare-`rubino sessions` entry the way Thor's subcommand dispatch
    # does — through #browse (the default_command). +tty+ flips the same gate
    # the real terminal does; the picker/list options are set on the instance.
    def run_browse(tty:, opts: {})
      allow($stdin).to receive(:tty?).and_return(tty)
      allow($stdout).to receive(:tty?).and_return(tty)
      cmd = described_class.new
      cmd.options = { limit: 20, all: false }.merge(opts)
      cmd.browse
    end

    it "off a TTY, bare `sessions` keeps the static list table (script-safe)" do
      repo.create(source: "cli", title: "piped-list")
      allow(Rubino::Workspace).to receive(:primary_root).and_return(nil)
      allow(ui).to receive(:select)

      run_browse(tty: false)

      table = ui.messages.find { |m| m[:level] == :table }
      expect(table).not_to be_nil
      titles = table[:message][:rows].map { |r| r[1].to_s }
      expect(titles).to include("piped-list")
      # Off a TTY it is the table, never the interactive picker.
      expect(ui).not_to have_received(:select)
    end

    it "explicit `sessions list` lists even on a TTY (never the picker)" do
      repo.create(source: "cli", title: "explicit-list")
      allow(Rubino::Workspace).to receive(:primary_root).and_return(nil)
      allow($stdout).to receive(:tty?).and_return(true)
      allow($stdin).to receive(:tty?).and_return(true)
      allow(ui).to receive(:select)

      cmd = described_class.new
      cmd.options = { limit: 20, all: false }
      cmd.list # the explicit verb, not browse

      table = ui.messages.find { |m| m[:level] == :table }
      expect(table).not_to be_nil
      expect(ui).not_to have_received(:select)
    end

    it "hands the picked id to the chat resume path (rubino chat --session <id>)" do
      allow(Rubino::Workspace).to receive(:primary_root).and_return(nil)
      s1 = repo.create(source: "cli", title: "first")
      s2 = repo.create(source: "cli", title: "second")
      # User highlights + Enter on the second row.
      allow(ui).to receive(:select).and_return(s2[:id])

      captured = nil
      fake_chat = instance_double(Rubino::CLI::ChatCommand, execute: nil)
      allow(Rubino::CLI::ChatCommand).to receive(:new) do |opts|
        captured = opts
        fake_chat
      end

      run_browse(tty: true)

      # The picker was offered over the listed sessions as [label, id] pairs.
      expect(ui).to have_received(:select) do |_prompt, choices|
        expect(choices.map(&:last)).to include(s1[:id], s2[:id])
        # Rows fold in msgs + recency, the shared Session::Picker label shape.
        label = choices.find { |_l, id| id == s2[:id] }.first
        expect(label).to include("second")
        expect(label).to match(/\d+ msgs?/)
      end
      # The chosen id is handed to ChatCommand exactly as `--session <id>` does.
      expect(captured[:session]).to eq(s2[:id])
      expect(fake_chat).to have_received(:execute)
    end

    it "does NOT boot a chat when the picker is cancelled (Esc)" do
      allow(Rubino::Workspace).to receive(:primary_root).and_return(nil)
      repo.create(source: "cli", title: "only")
      allow(ui).to receive(:select).and_return(nil) # Esc
      allow(Rubino::CLI::ChatCommand).to receive(:new)

      run_browse(tty: true)

      expect(Rubino::CLI::ChatCommand).not_to have_received(:new)
      expect(info_lines.join("\n")).to include("Cancelled")
    end

    it "shows the no-sessions message (not an empty picker) for an empty cwd" do
      # cwd-scoped to a dir with no sessions; the OTHER dir's session is hidden.
      repo.create(source: "cli", title: "elsewhere", cwd: "/home/dev/elsewhere")
      allow(Rubino::Workspace).to receive(:primary_root).and_return("/home/dev/empty")
      allow(ui).to receive(:select)
      allow(Rubino::CLI::ChatCommand).to receive(:new)

      run_browse(tty: true)

      expect(ui).not_to have_received(:select)
      expect(Rubino::CLI::ChatCommand).not_to have_received(:new)
      expect(info_lines.join("\n")).to include("No sessions found in this directory (try --all)")
    end

    it "--all seeds an UNSCOPED picker over every directory's sessions" do
      repo.create(source: "cli", title: "here", cwd: "/home/dev/here")
      repo.create(source: "cli", title: "there", cwd: "/home/dev/there")
      # Current dir has none — without --all this would be the no-sessions msg.
      allow(Rubino::Workspace).to receive(:primary_root).and_return("/home/dev/empty")
      allow(ui).to receive(:select).and_return(nil)
      allow(Rubino::CLI::ChatCommand).to receive(:new)

      run_browse(tty: true, opts: { all: true })

      expect(ui).to have_received(:select) do |_prompt, choices|
        labels = choices.map(&:first).join("\n")
        expect(labels).to include("here")
        expect(labels).to include("there")
      end
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
