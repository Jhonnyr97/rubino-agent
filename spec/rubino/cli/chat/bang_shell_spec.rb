# frozen_string_literal: true

# Behaviour specs for the `!` bang prefix (the human shell escape):
#   - a `!` line runs the command immediately — no approval — streaming its
#     output to the transcript with the `└ ✓/✗ exit` closing frame;
#   - command + output are injected into the SESSION STORE as two user-role
#     messages in Claude Code's bash-mode shape
#     (<bash-input>…</bash-input> then <bash-stdout>…</bash-stdout><bash-stderr>…</bash-stderr>),
#     so the model sees them next turn and they survive resume;
#   - context output is truncated head+tail past the per-stream cap;
#   - a nonzero exit / command-not-found carries an [exit code: N] marker;
#   - Ctrl+C terminates the COMMAND (not rubino) and marks the run interrupted;
#   - a bare `!` shows usage and runs/persists nothing;
#   - persisted bang messages replay as `! <cmd>` + a dim body, not raw tags.
RSpec.describe Rubino::CLI::Chat::BangShell do
  subject(:bang) { described_class.new }

  let(:db)     { test_database }
  let(:config) { test_configuration }
  let(:ui)     { Rubino::UI::Null.new }
  let(:store)  { Rubino::Session::Store.new(db: db.db) }
  let(:repo)   { Rubino::Session::Repository.new(db: db.db) }
  let(:session) do
    s = repo.create(source: "cli", model: "fake/test", provider: "fake")
    s[:persisted] = true
    s
  end
  let(:runner) { instance_double(Rubino::Agent::Runner, session: session) }

  before do
    allow(Rubino).to receive_messages(database: db, configuration: config)
  end

  def stored_contents
    store.for_session(session[:id]).map(&:content)
  end

  describe "#handle dispatch" do
    it "returns nil for a non-bang line (falls through to normal dispatch)" do
      expect(bang.handle("hello there", runner, ui)).to be_nil
      expect(stored_contents).to be_empty
    end

    it "shows usage and runs nothing for a bare `!`" do
      expect(bang.handle("!", runner, ui)).to eq(:handled)

      usage = ui.messages.find { |m| m[:level] == :status }
      expect(usage[:message]).to include("usage: ! <command>")
      expect(stored_contents).to be_empty
    end
  end

  describe "running a command (no approval, streamed, framed)" do
    it "executes immediately, streams the output, and closes with the ✓ exit frame" do
      out = capture_bang { bang.handle("! echo bang-hello", runner, ui) }

      expect(out).to include("bang-hello")
      expect(out).to match(/└ ✓ exit 0 · \d+(\.\d+)?(ms|s) · output → context/)
    end

    it "never consults the approval policy or the hardline guard (human-typed)" do
      allow(Rubino::Security::ApprovalPolicy).to receive(:new).and_call_original
      allow(Rubino::Security::HardlineGuard).to receive(:block_reason).and_call_original

      capture_bang { bang.handle("! echo gated?", runner, ui) }

      expect(Rubino::Security::ApprovalPolicy).not_to have_received(:new)
      expect(Rubino::Security::HardlineGuard).not_to have_received(:block_reason)
    end

    it "runs in the workspace root" do
      out = capture_bang { bang.handle("! pwd", runner, ui) }

      expect(out).to include(File.realpath(Rubino::Workspace.primary_root))
    end

    it "says (no output) for a command that prints nothing" do
      out = capture_bang { bang.handle("! true", runner, ui) }

      expect(out).to include("(no output)")
      expect(out).to include("✓ exit 0")
    end

    it "closes with the ✗ frame on a nonzero exit" do
      out = capture_bang { bang.handle("! exit 3", runner, ui) }

      expect(out).to include("└ ✗ exit 3")
    end
  end

  describe "context injection (the Claude Code bash-mode shape)" do
    it "persists <bash-input> then <bash-stdout><bash-stderr> as user-role messages" do
      result = nil
      capture_bang { result = bang.handle("! echo ctx-line", runner, ui) }
      expect(result).to eq(:ran)

      messages = store.for_session(session[:id])
      expect(messages.map(&:role)).to eq(%w[user user])
      expect(messages[0].content).to eq("<bash-input>echo ctx-line</bash-input>")
      expect(messages[1].content).to match(%r{\A<bash-stdout>ctx-line\n</bash-stdout><bash-stderr></bash-stderr>\z})
    end

    it "captures stderr separately in the <bash-stderr> tag" do
      capture_bang { bang.handle("! echo to-err 1>&2", runner, ui) }

      expect(stored_contents.last).to include("<bash-stderr>to-err\n</bash-stderr>")
      expect(stored_contents.last).to include("<bash-stdout></bash-stdout>")
    end

    it "marks a nonzero exit with [exit code: N] inside the stderr tag" do
      capture_bang { bang.handle("! exit 7", runner, ui) }

      expect(stored_contents.last).to include("[exit code: 7]</bash-stderr>")
    end

    it "carries a command-not-found like any other failure (stderr + exit code)" do
      capture_bang { bang.handle("! rubino-no-such-cmd-xyz", runner, ui) }

      # bash localizes the "command not found" text; assert the parts that
      # are stable across locales: the command name in stderr + exit 127.
      expect(stored_contents.last).to match(%r{<bash-stderr>.*rubino-no-such-cmd-xyz.*</bash-stderr>}m)
      expect(stored_contents.last).to include("[exit code: 127]")
    end

    it "updates the session message_count so /sessions stays honest" do
      capture_bang { bang.handle("! echo counted", runner, ui) }

      expect(repo.find(session[:id])[:message_count]).to eq(2)
    end

    it "lazily persists a brand-new (unsaved) session first (#144)" do
      unsaved = repo.build(source: "cli", model: "fake/test", provider: "fake")
      lazy_runner = instance_double(Rubino::Agent::Runner, session: unsaved)

      capture_bang { bang.handle("! echo first-contact", lazy_runner, ui) }

      expect(repo.persisted?(unsaved[:id])).to be(true)
      expect(store.for_session(unsaved[:id]).size).to eq(2)
    end

    it "truncates a stream past the cap, keeping head + tail with an omission marker" do
      capture_bang { bang.handle("! head -c 40000 /dev/zero | tr '\\0' 'a'", runner, ui) }

      payload = stored_contents.last
      expect(payload).to include("[... output truncated:")
      stdout_tag = payload[%r{<bash-stdout>(.*)</bash-stdout>}m, 1]
      expect(stdout_tag.length).to be < 40_000
      expect(stdout_tag).to start_with("a" * 100)
      expect(stdout_tag).to end_with("a" * 100)
    end
  end

  describe "Ctrl+C during a run" do
    it "terminates the command (not rubino), marks the run interrupted, and restores the INT trap" do
      int_handler = nil
      allow(Signal).to receive(:trap) do |sig, *_args, &blk|
        int_handler = blk if sig == "INT" && blk
        "PREV-HANDLER"
      end

      interrupter = Thread.new do
        sleep(0.05) until int_handler
        sleep(0.2)
        int_handler.call
      end

      result = nil
      out = capture_bang { result = bang.handle("! sleep 30", runner, ui) }
      interrupter.join

      expect(result).to eq(:ran)
      expect(out).to include("└ ✗ interrupted")
      expect(stored_contents.last).to include("[command interrupted by user (Ctrl+C)]")
      # The previous INT handler is restored on the way out.
      expect(Signal).to have_received(:trap).with("INT", "PREV-HANDLER")
    end
  end

  describe ".replay (resume history)" do
    it "replays a <bash-input> message as the `! <cmd>` echo" do
      expect(described_class.replay(ui, "<bash-input>npm test</bash-input>")).to be(true)

      echo = ui.messages.find { |m| m[:level] == :replay_user_input }
      expect(echo[:message]).to eq("! npm test")
    end

    it "replays the output message as a dim body block, never raw tags" do
      handled = described_class.replay(ui, "<bash-stdout>ok\n</bash-stdout><bash-stderr>warn\n</bash-stderr>")

      expect(handled).to be(true)
      body = ui.messages.find { |m| m[:level] == :tool_body }
      expect(body[:message]).to eq("ok\n\nwarn\n")
    end

    it "replays an empty capture as (no output)" do
      described_class.replay(ui, "<bash-stdout></bash-stdout><bash-stderr></bash-stderr>")

      body = ui.messages.find { |m| m[:level] == :tool_body }
      expect(body[:message]).to eq("(no output)")
    end

    it "leaves a normal user message alone" do
      expect(described_class.replay(ui, "what does ! do?")).to be(false)
      expect(ui.messages).to be_empty
    end
  end

  # Runs the block while capturing everything the bang path streams to
  # $stdout (the reader threads + closing frame write there directly).
  # Returns the captured text.
  def capture_bang
    prev = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = prev
  end
end
