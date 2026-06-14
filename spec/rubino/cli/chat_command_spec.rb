# frozen_string_literal: true

require "stringio"

RSpec.describe Rubino::CLI::ChatCommand do
  let(:db)      { test_database }
  let(:null_ui) { Rubino::UI::Null.new }

  let(:fake_runner) do
    instance_double(Rubino::Agent::Runner, run: "RESPONSE_TEXT", run!: "RESPONSE_TEXT")
  end

  before do
    allow(Rubino::Agent::Runner).to receive(:new).and_return(fake_runner)
    allow(Rubino).to receive(:database).and_return(db)
    allow(db).to receive(:healthy?).and_return(true)
    # These specs exercise boot/session/render paths, not the credential gate;
    # treat the model as configured so #ensure_model_configured! (the #93 gate,
    # covered by its own specs below) doesn't short-circuit them.
    allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(true)
    Rubino.ui = null_ui
  end

  # #111: the composer's quiet flag routes through the interrupt handler — a
  # quiet slash-command interrupt suppresses the UI's next `⎿ interrupted`
  # marker, then cancels; a loud one just cancels.
  describe "#interrupt_handler (#111)" do
    let(:turn_runner) { instance_double(Rubino::Agent::Runner, cancel!: nil) }

    it "suppresses the marker then cancels on a quiet interrupt" do
      ui = instance_double(Rubino::UI::CLI, suppress_interrupt_marker: nil)
      allow(Rubino).to receive(:ui).and_return(ui)

      described_class.new({}).send(:interrupt_handler, turn_runner).call(true)

      expect(ui).to have_received(:suppress_interrupt_marker)
      expect(turn_runner).to have_received(:cancel!)
    end

    it "just cancels on a loud interrupt" do
      ui = instance_double(Rubino::UI::CLI, suppress_interrupt_marker: nil)
      allow(Rubino).to receive(:ui).and_return(ui)

      described_class.new({}).send(:interrupt_handler, turn_runner).call(false)

      expect(ui).not_to have_received(:suppress_interrupt_marker)
      expect(turn_runner).to have_received(:cancel!)
    end

    it "degrades to cancel-only on a UI without the suppression seam" do
      allow(Rubino).to receive(:ui).and_return(Rubino::UI::Null.new)

      described_class.new({}).send(:interrupt_handler, turn_runner).call(true)

      expect(turn_runner).to have_received(:cancel!)
    end
  end

  # The status bar under the composer input: model id + context saturation,
  # built from the SAME estimator compaction runs on (Context::TokenBudget,
  # chars/4 over the stored session messages).
  describe "#build_status_line" do
    let(:cmd) { described_class.new({}) }
    let(:status_runner) do
      instance_double(Rubino::Agent::Runner, session: { id: "sess-1", model: "minimax-m3" })
    end

    def stub_store_with(messages)
      store = instance_double(Rubino::Session::Store)
      msgs  = messages.map do |attrs|
        instance_double(Rubino::Session::Message,
                        { content: "", metadata: {}, token_count: 0 }.merge(attrs))
      end
      allow(Rubino::Session::Store).to receive(:new).and_return(store)
      allow(store).to receive(:for_session).with("sess-1").and_return(msgs)
    end

    it "renders model + ctx % + tokens from the TokenBudget estimate" do
      stub_store_with([{ content: "x" * 4_000 }]) # 4000 chars / 4 = ~1000 tokens of the 128k default
      line = cmd.send(:build_status_line, status_runner)
      expect(line).to include("minimax-m3")
      expect(line).to include("ctx ~1k/128k")
      expect(line).to include("(1%)")
    end

    # Rail rubino: the mode chip moved off the prompt into the status bar —
    # the MODE token leads the line, with the branch / active-skill tokens
    # after it when set.
    it "leads with the mode token (the chip moved off the prompt)" do
      stub_store_with([{ content: "hi" }])
      line = cmd.send(:build_status_line, status_runner).gsub(/\e\[[0-9;]*m/, "")
      expect(line).to start_with(" default · ")
    end

    it "shows the active skill as a `skill <name>` token after the mode" do
      Rubino::ActiveSkill.set("ruby-expert")
      stub_store_with([{ content: "hi" }])
      line = cmd.send(:build_status_line, status_runner).gsub(/\e\[[0-9;]*m/, "")
      expect(line).to start_with(" default · skill ruby-expert · minimax-m3")
    ensure
      Rubino::ActiveSkill.reset!
    end

    it "shows the branch token after a /branch fork" do
      cmd.instance_variable_set(:@branch_short_id, "ab12cd")
      stub_store_with([{ content: "hi" }])
      line = cmd.send(:build_status_line, status_runner).gsub(/\e\[[0-9;]*m/, "")
      expect(line).to start_with(" default · branch:ab12cd · ")
    end

    it "prefers the last response's REAL recorded usage over the estimate" do
      # The newest assistant message carries the provider-reported context
      # (input_tokens, persisted by the agent loop) — that wins over chars/4.
      stub_store_with([
                        { content: "hi" },
                        { content: "ok", metadata: { input_tokens: 7_800 }, token_count: 200 }
                      ])
      line = cmd.send(:build_status_line, status_runner)
      expect(line).to include("ctx ~8k/128k") # 7800 + 200
      expect(line).to include("(6%)")
    end

    it "honours model.context_length as the window" do
      stub_store_with([{ content: "x" * 256_000 }]) # ~64k tokens
      allow(Rubino).to receive(:configuration)
        .and_return(test_configuration("model" => { "context_length" => 64_000 }))
      expect(cmd.send(:build_status_line, status_runner)).to include("100%")
    end

    it "returns nil when display.statusbar is disabled" do
      allow(Rubino).to receive(:configuration)
        .and_return(test_configuration("display" => { "statusbar" => false }))
      expect(cmd.send(:build_status_line, status_runner)).to be_nil
    end

    it "returns nil without a runner (cooked/standalone paths)" do
      expect(cmd.send(:build_status_line, nil)).to be_nil
    end

    it "never raises — a store failure degrades to no bar" do
      allow(Rubino::Session::Store).to receive(:new).and_raise(RuntimeError, "db gone")
      expect(cmd.send(:build_status_line, status_runner)).to be_nil
    end
  end

  # Regression: ensure_setup! must populate the tool registry. If it doesn't,
  # Lifecycle#load_tools returns []; RubyLLMAdapter#build_chat never calls
  # chat.with_tool; the request body sent to the provider has no `tools`
  # field; the model can only roleplay bash in markdown. Verified against
  # real wire traffic via RUBYLLM_DEBUG=1 before this fix.
  describe "#ensure_setup!" do
    it "registers default tools when the registry is empty" do
      expect(Rubino::Tools::Registry.all.size).to eq(0)

      described_class.new({}).send(:ensure_setup!)

      expect(Rubino::Tools::Registry.all.size).to be > 0
      expect(Rubino::Tools::Registry.find("shell")).not_to be_nil
      expect(Rubino::Tools::Registry.find("read")).not_to be_nil
      expect(Rubino::Tools::Registry.find("write")).not_to be_nil
    end

    it "re-registers defaults when a core tool is missing from a partial registry" do
      Rubino::Tools::Registry.register(Rubino::Tools::ShellTool.new)

      described_class.new({}).send(:ensure_setup!)

      # A partially-populated registry (e.g. leaked by a test or a plugin
      # registering early) must still get the core defaults back — gating on
      # emptiness alone caused "Unknown tool: write" boots (#163 class).
      expect(Rubino::Tools::Registry.find("write")).not_to be_nil
      expect(Rubino::Tools::Registry.find("read")).not_to be_nil
    end

    it "leaves a fully-populated registry alone (no churn when core tools present)" do
      Rubino::Tools::Registry.register_defaults!
      shell_instance = Rubino::Tools::Registry.find("shell")

      described_class.new({}).send(:ensure_setup!)

      # Core tools present → no re-registration, existing instances kept.
      expect(Rubino::Tools::Registry.find("shell")).to equal(shell_instance)
    end
  end

  # -----------------------------------------------------------------------
  # One-shot detection
  # -----------------------------------------------------------------------

  describe "#execute — one-shot detection" do
    it "calls run_oneshot when :query given" do
      cmd = described_class.new(query: "hello")
      expect(cmd).to receive(:run_oneshot).with("hello")
      cmd.execute
    end

    it "calls run_oneshot when 'query' string key given (Thor)" do
      cmd = described_class.new("query" => "hello")
      expect(cmd).to receive(:run_oneshot).with("hello")
      cmd.execute
    end

    it "calls run_interactive when no query" do
      cmd = described_class.new({})
      expect(cmd).to receive(:run_interactive)
      cmd.execute
    end
  end

  # -----------------------------------------------------------------------
  # One-shot output
  # -----------------------------------------------------------------------

  describe "#run_oneshot output" do
    it "prints response to stdout" do
      expect { described_class.new("query" => "ping").execute }.to output("RESPONSE_TEXT\n").to_stdout
    end

    it "prints response in quiet mode" do
      expect { described_class.new("query" => "ping", "quiet" => true).execute }.to output("RESPONSE_TEXT\n").to_stdout
    end

    it "prints response in scripted mode" do
      expect { described_class.new("query" => "ping", "z" => true).execute }.to output("RESPONSE_TEXT\n").to_stdout
    end

    it "passes Null UI to Runner" do
      described_class.new("query" => "ping").execute
      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(ui: an_instance_of(Rubino::UI::Null))
      )
    end

    # #69 — one-shot answers go through the SAME markdown pipeline interactive
    # chat uses when a human is watching (stdout is a TTY): no literal `**` /
    # raw pipe tables at the prompt. Piped stdout stays raw byte-for-byte —
    # `answer=$(rubino prompt ...)` depends on plain text.
    it "renders markdown via the interactive pipeline when stdout is a TTY (#69)" do
      allow(fake_runner).to receive(:run!).and_return("**bold** and `code`")
      rendered = nil
      expect do
        # The output matcher has already swapped $stdout for its capture IO
        # here, so the tty? stub lands on the capture and flips the TTY path.
        allow($stdout).to receive(:tty?).and_return(true)
        described_class.new("query" => "ping").execute
      end.to output(satisfy { |s| rendered = s }).to_stdout
      expect(rendered).to include("bold")
      expect(rendered).not_to include("**bold**")
    end

    it "keeps raw markdown byte-for-byte when stdout is piped (#69)" do
      allow(fake_runner).to receive(:run!).and_return("**bold** and `code`")
      expect { described_class.new("query" => "ping").execute }
        .to output("**bold** and `code`\n").to_stdout
    end
  end

  # -----------------------------------------------------------------------
  # Model / provider
  # -----------------------------------------------------------------------

  describe "model and provider options" do
    it "passes model override to Runner (symbol key)" do
      described_class.new(query: "hi", model: "claude-3-5-sonnet-20241022").execute
      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(model_override: "claude-3-5-sonnet-20241022")
      )
    end

    it "passes model override to Runner (string key / Thor)" do
      described_class.new("query" => "hi", "model" => "claude-3-5-sonnet-20241022").execute
      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(model_override: "claude-3-5-sonnet-20241022")
      )
    end

    it "passes -m alias to Runner" do
      described_class.new("query" => "hi", "m" => "gpt-4o").execute
      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(model_override: "gpt-4o")
      )
    end

    it "passes provider override to Runner" do
      described_class.new("query" => "hi", "provider" => "anthropic").execute
      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(provider_override: "anthropic")
      )
    end

    it "uses default model when no override" do
      described_class.new("query" => "hi").execute
      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(model_override: Rubino.configuration.model_default)
      )
    end

    # #141: --max-turns must reach the Runner (which threads it into the budget).
    it "passes --max-turns to the Runner as max_turns" do
      described_class.new("query" => "hi", "max_turns" => 3.0).execute
      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(max_turns: 3.0)
      )
    end

    it "passes max_turns: nil when the flag is absent" do
      described_class.new("query" => "hi").execute
      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(max_turns: nil)
      )
    end
  end

  # -----------------------------------------------------------------------
  # #142: one-shot model echo + unknown-model warning
  # -----------------------------------------------------------------------
  describe "resolved-model echo & unknown-model warning (#142)" do
    it "echoes the resolved model to stderr in -q mode when -m is given (known model)" do
      expect do
        described_class.new("query" => "hi", "model" => "gpt-4o").execute
      end.to output(/model: gpt-4o/).to_stderr
    end

    it "warns to stderr when the -m model id is not in the known catalog" do
      expect do
        described_class.new("query" => "hi", "model" => "zzz-nonexistent-9999").execute
      end.to output(/warning: model 'zzz-nonexistent-9999' is not in the known model catalog/).to_stderr
    end

    it "still proceeds (prints the answer) on an unknown model id" do
      expect do
        described_class.new("query" => "hi", "model" => "zzz-nonexistent-9999").execute
      end.to output("RESPONSE_TEXT\n").to_stdout
    end

    it "does NOT echo the model when no -m override is given" do
      expect do
        described_class.new("query" => "hi").execute
      end.not_to output(/^model: /).to_stderr
    end

    it "does not warn for a fake/ model id (dev provider)" do
      expect do
        described_class.new("query" => "hi", "model" => "fake/with-tools").execute
      end.not_to output(/not in the known model catalog/).to_stderr
    end
  end

  # -----------------------------------------------------------------------
  # Session management
  # -----------------------------------------------------------------------

  describe "session management" do
    let(:repo) { instance_double(Rubino::Session::Repository) }
    let(:session) { { id: "abc123ef", title: "my session", status: "active" } }

    before do
      allow(Rubino::Session::Repository).to receive(:new).and_return(repo)
      # resolve_session_id reaps orphaned-active sessions (#11) before resolving.
      allow(repo).to receive(:reap_orphaned_active!)
    end

    it "passes --session ID to Runner" do
      described_class.new("query" => "hi", "session" => "abc123ef").execute
      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(session_id: "abc123ef")
      )
    end

    it "passes --resume to Runner" do
      described_class.new("query" => "hi", "resume" => "xyz789").execute
      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(session_id: "xyz789")
      )
    end

    it "--continue fetches latest resumable session" do
      allow(repo).to receive(:latest_resumable_for_cwd).and_return(session)
      described_class.new("query" => "hi", "continue" => true).execute
      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(session_id: "abc123ef")
      )
    end

    it "--continue passes nil when no resumable session" do
      allow(repo).to receive(:latest_resumable_for_cwd).and_return(nil)
      described_class.new("query" => "hi", "continue" => true).execute
      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(session_id: nil)
      )
    end

    it "passes nil session_id when no session option" do
      described_class.new("query" => "hi").execute
      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(session_id: nil)
      )
    end
  end

  # -----------------------------------------------------------------------
  # #99 / #100 / #103: bare-chat auto-resume, end-on-teardown, auto-title.
  # Drives the real interactive REPL with a faked runner; the line input
  # immediately returns "/exit" so a single teardown is exercised.
  # -----------------------------------------------------------------------
  describe "bare-chat resume + teardown (#99/#100)" do
    let(:repo) { Rubino::Session::Repository.new(db: db.db) }

    let(:resumed_session) { { id: "deadbeefcafef00d", title: "add modulo op", status: "active" } }
    let(:new_session)     { { id: "00000000fresh000", title: nil, status: "active" } }

    before do
      allow(Rubino::Session::Repository).to receive(:new).and_return(repo)
      # Drive the REPL: first prompt read exits immediately.
      # No TTY composer in the test environment → the cooked fallback reads the
      # next line; make it submit /exit so the REPL loop terminates.
      allow(Rubino::UI::BottomComposer).to receive(:active?).and_return(false)
      allow_any_instance_of(described_class).to receive(:cooked_input).and_return("/exit")
      allow(fake_runner).to receive(:end_session!)
      allow(fake_runner).to receive(:cancel!)
      # Avoid touching git in the banner.
      allow_any_instance_of(described_class).to receive(:git_context).and_return(nil)
    end

    it "auto-resumes the most recent resumable session on a bare chat" do
      allow(repo).to receive(:latest_resumable_for_cwd).and_return(resumed_session)
      allow(fake_runner).to receive(:session).and_return(resumed_session)

      described_class.new({}).execute

      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(session_id: resumed_session[:id])
      )
    end

    it "prints the resume one-liner so the continuation is never silent" do
      allow(repo).to receive(:latest_resumable_for_cwd).and_return(resumed_session)
      allow(fake_runner).to receive(:session).and_return(resumed_session)

      described_class.new({}).execute

      line = null_ui.messages.find { |m| m[:message].to_s.include?("resuming") }
      expect(line).not_to be_nil
      expect(line[:message]).to include("/new for a fresh session")
    end

    it "starts a fresh session (and welcomes) on a true first run" do
      allow(repo).to receive(:latest_resumable_for_cwd).and_return(nil)
      allow(fake_runner).to receive(:session).and_return(new_session)

      described_class.new({}).execute

      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(session_id: nil)
      )
      welcome = null_ui.messages.find { |m| m[:message].to_s.include?("ask in plain language") }
      expect(welcome).not_to be_nil
    end

    it "--new forces a fresh session even when one is resumable" do
      allow(repo).to receive(:latest_resumable_for_cwd).and_return(resumed_session)
      allow(fake_runner).to receive(:session).and_return(new_session)

      described_class.new("new" => true).execute

      expect(Rubino::Agent::Runner).to have_received(:new).with(
        hash_including(session_id: nil)
      )
    end

    it "marks the session ended on a clean teardown (#100)" do
      allow(repo).to receive(:latest_resumable_for_cwd).and_return(nil)
      allow(fake_runner).to receive(:session).and_return(new_session)

      described_class.new({}).execute

      expect(fake_runner).to have_received(:end_session!)
    end
  end

  # #11: closing a terminal tab delivers SIGHUP; a session left "active" must be
  # stamped ended_at by the installed trap, the same as SIGTERM. SIGKILL cannot
  # be trapped — that path is covered by Repository#reap_orphaned_active!.
  describe "SIGHUP/close teardown trap (#11)" do
    let(:runner) { instance_double(Rubino::Agent::Runner) }

    around do |example|
      prev = Signal.trap("HUP", "DEFAULT")
      example.run
    ensure
      Signal.trap("HUP", prev || "DEFAULT")
    end

    it "installs a HUP handler that ends the session on close" do
      skip "SIGHUP not supported on this platform" unless Signal.list.key?("HUP")
      allow(runner).to receive(:end_session!)

      cmd = described_class.new({})
      prev = cmd.send(:install_session_end_traps, runner)
      expect(prev).to have_key("HUP")

      # Capture the installed handler (Signal.trap returns the prior one) and
      # invoke it directly. Firing a real SIGHUP would exit(0) the rspec
      # process; the handler ends the session then exits, so we assert both.
      handler = Signal.trap("HUP", "DEFAULT")
      expect(handler).to respond_to(:call)
      expect { handler.call }.to raise_error(SystemExit)

      expect(runner).to have_received(:end_session!)
    end
  end

  # -----------------------------------------------------------------------
  # --yolo
  # -----------------------------------------------------------------------

  describe "--yolo flag" do
    it "switches Rubino::Modes to :yolo (ApprovalPolicy short-circuits from there)" do
      described_class.new("query" => "hi", "yolo" => true).execute
      expect(Rubino::Modes.current).to eq(:yolo)
    end

    it "leaves Modes at :default without --yolo" do
      described_class.new("query" => "hi").execute
      expect(Rubino::Modes.current).to eq(:default)
    end
  end

  # Regression: text typed into the bottom composer DURING a turn but never
  # submitted (no Enter) was lost when the turn ended — the composer is torn
  # down and the next prompt is a fresh, empty Reline read. The draft is now
  # carried over: stop_composer stashes the leftover buffer and next_input
  # pre-fills the following prompt with it.
  describe "un-submitted composer draft carryover" do
    let(:cmd)         { described_class.new({}) }
    let(:input_queue) { Rubino::Interaction::InputQueue.new }

    def fake_composer(buffer)
      Class.new do
        def initialize(buf) = @buf = buf
        def buffer = @buf
        def stop; end
      end.new(buffer)
    end

    it "stashes a non-empty leftover buffer as the pending draft" do
      cmd.send(:stop_composer, fake_composer("ciao"), nil)
      expect(cmd.instance_variable_get(:@pending_draft)).to eq("ciao")
    end

    it "leaves a prior draft untouched when the buffer is blank (survives steering turns)" do
      cmd.instance_variable_set(:@pending_draft, "earlier")
      cmd.send(:stop_composer, fake_composer("   "), nil)
      expect(cmd.instance_variable_get(:@pending_draft)).to eq("earlier")
    end

    it "pre-fills the next prompt with the pending draft and consumes it once" do
      cmd.instance_variable_set(:@pending_draft, "half typed")
      # Non-TTY → cooked fallback: it pre-pends the carried-over draft to the
      # typed line.
      allow(Rubino::UI::BottomComposer).to receive(:active?).and_return(false)
      allow($stdin).to receive(:gets).and_return(" rest\n")
      allow($stdout).to receive(:print)
      allow($stdout).to receive(:flush)

      expect(cmd.send(:next_input, input_queue)).to eq("half typed rest")
      expect(cmd.instance_variable_get(:@pending_draft)).to be_nil
    end

    it "prefers queued (submitted) lines over the draft, leaving the draft pending" do
      cmd.instance_variable_set(:@pending_draft, "draft")
      input_queue.push("submitted line")

      expect(cmd.send(:next_input, input_queue)).to eq("submitted line")
      expect(cmd.instance_variable_get(:@pending_draft)).to eq("draft")
    end
  end

  # Interrupt-by-default / queue plumbing: a line that came off the input queue
  # (typed during the previous turn — interrupt-by-default Enter, Alt+Enter, or
  # /queued) is flagged so run_turn commits its normal "<prompt><line>" echo and
  # removes any "⏳ queued:" indicator. An idle submit (read_idle_line) is NOT
  # flagged, so it isn't double-echoed.
  describe "queued-prompt commit (#input_from_queue / #commit_queued_prompt)" do
    let(:cmd) { described_class.new({}) }
    let(:input_queue) { Rubino::Interaction::InputQueue.new }

    it "flags a drained-from-queue line for run_turn to echo" do
      input_queue.push("interrupt-sent")
      cmd.send(:next_input, input_queue)
      expect(cmd.instance_variable_get(:@input_from_queue)).to eq(["interrupt-sent"])
    end

    it "commit_queued_prompt echoes <prompt><line> and clears the matching indicator" do
      cmd.instance_variable_set(:@input_from_queue, ["do later"])
      composer = instance_spy(Rubino::UI::BottomComposer)

      cmd.send(:commit_queued_prompt, composer)

      expect(composer).to have_received(:commit_queued).with("do later")
      # The committed echo uses the clean rail-free "❯ " form (Rail rubino).
      expect(composer).to have_received(:print_above).with("❯ do later")
      expect(cmd.instance_variable_get(:@input_from_queue)).to be_nil
    end

    it "is a no-op when the prompt was an idle submit (not flagged)" do
      cmd.instance_variable_set(:@input_from_queue, nil)
      composer = instance_spy(Rubino::UI::BottomComposer)
      cmd.send(:commit_queued_prompt, composer)
      expect(composer).not_to have_received(:print_above)
    end
  end

  # #192 — a dequeued line that resolves to a SLASH COMMAND (or any non-turn
  # branch: `!` shell escape, `? ` probe, image command) never reaches
  # #run_turn, so #commit_queued_prompt never fired for it and its live
  # "⏳ queued:" indicator leaked across later prompts. The dispatch loop now
  # commits it via #commit_queued_dispatch when the line is consumed.
  describe "queued line consumed off the turn path (#192)" do
    let(:cmd) { described_class.new({}) }

    it "commit_queued_dispatch drops the pending row and echoes the line" do
      cmd.send(:pending_queued) << "/status"
      cmd.instance_variable_set(:@input_from_queue, ["/status"])

      expect { cmd.send(:commit_queued_dispatch) }.to output("❯ /status\n").to_stdout

      expect(cmd.send(:pending_queued)).to eq([])
      expect(cmd.instance_variable_get(:@input_from_queue)).to be_nil
    end

    it "is a no-op for an idle submit (not flagged)" do
      cmd.send(:pending_queued) << "later"
      cmd.instance_variable_set(:@input_from_queue, nil)

      expect { cmd.send(:commit_queued_dispatch) }.not_to output.to_stdout

      expect(cmd.send(:pending_queued)).to eq(["later"]) # untouched: still pending
    end

    it "clears the indicator end-to-end when a queued line runs as a slash command" do
      allow(Rubino::UI::BottomComposer).to receive(:active?).and_return(false)
      allow(Rubino::Commands::Executor).to receive(:welcome)
      allow(fake_runner).to receive_messages(session: { id: "sess-192", title: nil, model: "m" },
                                             end_session!: nil)
      allow(cmd).to receive_messages(setup_workspace_and_trust!: nil, git_context: nil,
                                     redirect_logger_to_file: nil)
      allow($stdin).to receive(:gets).and_return("go\n", nil)
      allow(fake_runner).to receive(:run) do |_prompt, input_queue:, **|
        # Mid-turn the user explicitly queues a slash command (Alt+Enter / /queued).
        cmd.send(:pending_queued) << "/help"
        input_queue.push("/help")
        "ok"
      end

      expect { cmd.send(:run_interactive) }.to output(%r{/help}).to_stdout

      expect(cmd.send(:pending_queued)).to eq([])                    # the ⏳ row is gone
      expect(cmd.instance_variable_get(:@input_from_queue)).to be_nil
      expect(fake_runner).to have_received(:run).once                # /help never ran a model turn
    end
  end

  # -----------------------------------------------------------------------
  # ensure_setup!
  # -----------------------------------------------------------------------

  # F2: a fresh user who runs `chat` before `setup` used to hit a raw
  # `no such table: sessions` backtrace — `healthy?` only runs SELECT 1, which
  # passes the moment SQLite lazily creates an empty file (no schema). The
  # first-run guard now auto-initializes (mkdir + migrate, both idempotent),
  # and only falls back to a friendly message if that itself fails.
  describe "ensure_setup! (first-run auto-init)" do
    it "auto-initializes an un-migrated database instead of crashing" do
      allow(db).to receive(:healthy?).and_return(false)
      migrator = instance_double(Rubino::Database::Migrator, pending?: true)
      allow(Rubino::Database::Migrator).to receive(:new).and_return(migrator)
      allow(Rubino).to receive(:ensure_directories!)
      expect(migrator).to receive(:migrate!)

      expect { described_class.new("query" => "hi").execute }.not_to raise_error
    end

    it "runs pending migrations on a healthy-but-stale database" do
      migrator = instance_double(Rubino::Database::Migrator, pending?: true)
      allow(Rubino::Database::Migrator).to receive(:new).and_return(migrator)
      allow(Rubino).to receive(:ensure_directories!)
      expect(migrator).to receive(:migrate!)

      described_class.new("query" => "hi").execute
    end

    it "exits with a friendly message (not a backtrace) when auto-init fails" do
      allow(db).to receive(:healthy?).and_return(false)
      migrator = instance_double(Rubino::Database::Migrator, pending?: true)
      allow(Rubino::Database::Migrator).to receive(:new).and_return(migrator)
      allow(Rubino).to receive(:ensure_directories!)
      allow(migrator).to receive(:migrate!).and_raise(StandardError, "disk full")

      expect do
        described_class.new("query" => "hi").execute
      end.to raise_error(SystemExit).and output(/rubino setup/).to_stderr
    end
  end

  # Regression: --resume <id> reloaded the history into the backend
  # (PromptAssembler reads Session::Store.for_session) but never printed
  # the prior turns through the inline UI. The terminal looked empty even
  # though the model had full context. print_session_history replays
  # user / assistant / tool messages through the existing UI methods.
  describe "#print_session_history" do
    let(:repo)  { Rubino::Session::Repository.new }
    let(:store) { Rubino::Session::Store.new }
    let(:session) { repo.create(source: "spec", model: "test", provider: "test") }

    before do
      allow(Rubino::Session::Repository).to receive(:new).and_call_original
      allow(Rubino::Session::Store).to receive(:new).and_call_original
    end

    it "no-ops when session_id is nil" do
      ui = Rubino::UI::Null.new
      Rubino::CLI::Chat::SessionResolver.new({}).print_session_history(ui, nil)
      expect(ui.messages).to be_empty
    end

    it "no-ops when the session has no messages" do
      ui = Rubino::UI::Null.new
      Rubino::CLI::Chat::SessionResolver.new({}).print_session_history(ui, session[:id])
      expect(ui.messages).to be_empty
    end

    it "replays user, assistant and tool messages through the UI" do
      store.create(session_id: session[:id], role: "user",      content: "hello")
      store.create(session_id: session[:id], role: "assistant", content: "hi there")
      store.create(session_id: session[:id], role: "tool",      content: "out",
                   tool_name: "shell", tool_call_id: "call_1",
                   metadata: { arguments: { "command" => "ls" } })

      ui = Rubino::UI::Null.new
      Rubino::CLI::Chat::SessionResolver.new({}).print_session_history(ui, session[:id])

      levels = ui.messages.map { |m| m[:level] }
      # Replay matches the live rendering: user → replay_user_input, assistant →
      # assistant_text (markdown, same as a live reply — NOT the old box, which
      # the M2 redesign repurposed into a "● running" tool-style row), tool →
      # tool_started + tool_finished.
      expect(levels).to include(:replay_user_input, :assistant_text,
                                :tool_started, :tool_finished)
      expect(levels).not_to include(:box_open, :box_close)

      # Tool replay must carry an `at:` timestamp so historical tool boxes
      # show the original time of the call, not "now". Previously the tool
      # branch dropped `at:` and every replayed tool showed the current
      # clock — confusing on long-resumed sessions.
      started = ui.messages.find { |m| m[:level] == :tool_started }
      expect(started[:at]).not_to be_nil
      expect(ui.messages.find { |m| m[:level] == :replay_user_input }[:message]).to eq("hello")
      started = ui.messages.find { |m| m[:level] == :tool_started }
      expect(started[:message]).to eq("shell")
      # Store#hydrate deserialises metadata_json with symbolize_names: true,
      # so the string key persisted by Loop comes back as a symbol. The UI
      # treats both transparently — what matters is that the args survive.
      expect(started[:arguments]).to eq({ command: "ls" })
    end

    it "replays `!` bang messages as the echo + dim output, never raw tags" do
      store.create(session_id: session[:id], role: "user",
                   content: "<bash-input>git status</bash-input>")
      store.create(session_id: session[:id], role: "user",
                   content: "<bash-stdout>clean\n</bash-stdout><bash-stderr></bash-stderr>")

      ui = Rubino::UI::Null.new
      Rubino::CLI::Chat::SessionResolver.new({}).print_session_history(ui, session[:id])

      echo = ui.messages.find { |m| m[:level] == :replay_user_input }
      expect(echo[:message]).to eq("! git status")
      body = ui.messages.find { |m| m[:level] == :tool_body }
      expect(body[:message]).to eq("clean\n")
      raw = ui.messages.find { |m| m[:message].to_s.include?("<bash-") }
      expect(raw).to be_nil
    end

    it "skips assistant messages whose content is blank" do
      store.create(session_id: session[:id], role: "user",      content: "ping")
      store.create(session_id: session[:id], role: "assistant", content: "")

      ui = Rubino::UI::Null.new
      Rubino::CLI::Chat::SessionResolver.new({}).print_session_history(ui, session[:id])

      bodies = ui.messages.select { |m| m[:level] == :body }
      expect(bodies).to be_empty
    end
  end

  # Regression: with the fullscreen TUI gone, Ctrl+C during a turn must
  # cancel the in-flight generation and drop back to the prompt instead
  # of killing the whole REPL. Aider-style double-tap: a SECOND Ctrl+C
  # within DOUBLE_TAP_SECONDS exits. The SIGINT handler is trap-safe (it
  # only flips the mutex-free CancelToken) and is restored in ensure.
  # Driven via run_turn directly to avoid readline.
  describe "#run_turn (Ctrl+C semantics)" do
    let(:runner) { instance_double(Rubino::Agent::Runner) }
    let(:ui)     { Rubino::UI::Null.new }
    let(:cmd)    { described_class.new({}) }

    # Captures the SIGINT handler the trap installs so the test can fire it
    # synchronously, the way the kernel would on Ctrl+C, without sending a
    # real signal (which would be flaky under the RSpec runner).
    def run_turn_firing_int(runner, taps:, gap: 0.0)
      installed = nil
      allow(runner).to receive(:run) do
        installed = Signal.trap("INT", "DEFAULT")          # read what run_turn installed
        Signal.trap("INT", installed)                      # put it back
        taps.times do |i|
          sleep gap if i.positive? && gap.positive?
          installed.call
        end
        "ok"
      end
      cmd.send(:run_turn, runner, "hello", ui)
    end

    it "first Ctrl+C flips the token, warns the user, and stays in the REPL" do
      allow(runner).to receive(:cancel!)
      warned = nil
      allow($stderr).to receive(:write) { |s| warned = s }

      expect { run_turn_firing_int(runner, taps: 1) }.not_to raise_error

      expect(runner).to have_received(:cancel!).at_least(:once)
      expect(warned).to include("Ctrl+C again to exit")
    end

    it "second Ctrl+C within the window re-raises so the REPL exits" do
      allow(runner).to receive(:cancel!)
      allow($stderr).to receive(:write)
      # The second tap restores prev and re-kills INT; in-process that lands
      # as an Interrupt out of runner.run, which run_turn re-raises.
      expect { run_turn_firing_int(runner, taps: 2) }.to raise_error(Interrupt)
      expect(runner).to have_received(:cancel!).at_least(:once)
    end

    it "calls runner.cancel! and warns when Interrupt escapes mid-turn" do
      allow(runner).to receive(:run).and_raise(Interrupt)
      allow(runner).to receive(:cancel!)

      expect { cmd.send(:run_turn, runner, "hello", ui) }.to raise_error(Interrupt)

      expect(runner).to have_received(:cancel!).at_least(:once)
      expect(ui.messages.map { |m| m[:level] }).to include(:warning)
    end

    it "returns normally when the turn completes without interruption" do
      allow(runner).to receive(:run).and_return("ok")

      expect { cmd.send(:run_turn, runner, "hello", ui) }.not_to raise_error
      expect(runner).to have_received(:run).with("hello", image_paths: [], input_queue: nil)
    end

    it "restores the previous SIGINT handler in ensure" do
      before = Signal.trap("INT", "DEFAULT")
      Signal.trap("INT", before)
      allow(runner).to receive(:run).and_return("ok")

      cmd.send(:run_turn, runner, "hello", ui)

      after = Signal.trap("INT", before)
      Signal.trap("INT", before)
      expect(after).to eq(before)
    end
  end

  # The paste pipeline's message-build seam: run_turn keeps the compact
  # "[Pasted text #N +M lines]" placeholder IN the prompt (so the persisted
  # message — and thus the live echo AND resume replay — stays clean, #213)
  # while COLLECTING each placeholder's expansion (full body for tier 1, the
  # paste_N.txt read-tool pointer for tier 2) and handing it to runner.run as
  # paste_expansions metadata. The expansion is folded into the model-facing
  # content downstream by Message#to_context.
  describe "#run_turn — paste placeholder expansion" do
    let(:runner) { instance_double(Rubino::Agent::Runner) }
    let(:ui)     { Rubino::UI::Null.new }
    let(:cmd)    { described_class.new({}) }

    it "keeps the placeholder in the prompt and carries the FULL body as metadata (tier 1, #213)" do
      body  = Array.new(50) { |i| "line #{i + 1}" }.join("\n")
      token = cmd.send(:paste_store).register(body)
      allow(runner).to receive(:run).and_return("ok")

      cmd.send(:run_turn, runner, "quote #{token} please", ui)

      expect(runner).to have_received(:run)
        .with("quote #{token} please",
              image_paths: [], input_queue: nil,
              paste_expansions: [[token, body]])
    end

    it "carries the read-tool pointer as metadata for a tier-2 overflowed paste" do
      body  = Array.new(10_000) { |i| "overflow line #{i + 1}" }.join("\n") # ≫ 8k tokens
      token = cmd.send(:paste_store).register(body)
      allow(runner).to receive(:run).and_return("ok")

      cmd.send(:run_turn, runner, token, ui)

      expect(runner).to have_received(:run) do |prompt, paste_expansions:, **_kw|
        # The PROMPT keeps the compact placeholder, never the body.
        expect(prompt).to eq(token)
        expect(prompt).not_to include("overflow line 42")

        pointer = paste_expansions.first.last
        expect(pointer).to include("saved to")
        expect(pointer).to include("paste_1.txt")
        expect(pointer).to include("read it with the read tool")
        path = pointer[/saved to (\S+)/, 1]
        expect(File.read(path)).to eq(body)
      end
    end
  end

  # Steering — "talk to the agent while it works". A background reader keeps
  # accepting keystrokes while a turn runs; completed lines are parked in an
  # InputQueue and become the NEXT prompt at the turn boundary (never injected
  # mid-tool). Combined with the existing Ctrl+C cancel, this gives both
  # "queue while working" and "interrupt then redirect".
  describe "steering (type-while-busy queue)" do
    let(:cmd) { described_class.new({}) }
    let(:ui)  { Rubino::UI::Null.new }

    describe "#next_input (turn-boundary consumption)" do
      let(:input_queue) { Rubino::Interaction::InputQueue.new }

      before do
        # Non-TTY in the suite → the cooked fallback handles the idle read.
        allow(Rubino::UI::BottomComposer).to receive(:active?).and_return(false)
      end

      it "consumes queued lines as the next prompt INSTEAD of reading a fresh line" do
        input_queue.push("steered message")
        expect(cmd).not_to receive(:cooked_input)

        expect(cmd.send(:next_input, input_queue)).to eq("steered message")
      end

      it "runs each queued line as its OWN turn, in submission order (B4)" do
        input_queue.push("first")
        input_queue.push("second")
        expect(cmd).not_to receive(:cooked_input)

        # First boundary takes only "first" (NOT "first\nsecond"); "second"
        # stays parked and is taken as its own next turn.
        expect(cmd.send(:next_input, input_queue)).to eq("first")
        expect(cmd.send(:next_input, input_queue)).to eq("second")
        expect(input_queue.pending?).to be(false)
      end

      it "reads a fresh line when the queue is empty" do
        allow(cmd).to receive(:cooked_input).and_return("typed at prompt")

        expect(cmd.send(:next_input, input_queue)).to eq("typed at prompt")
        expect(cmd).to have_received(:cooked_input)
      end
    end

    # The composer is the single idle input path on a TTY: it pins the prompt,
    # owns its raw reader, and hosts the collapsed subagent card region (F1) when
    # children are live. Off a TTY (the suite), #next_input takes the cooked
    # fallback. These specs assert the TTY routing chooses the composer.
    describe "#next_input idle composer routing (TTY)" do
      let(:input_queue) { Rubino::Interaction::InputQueue.new }
      let(:registry)    { Rubino::Tools::BackgroundTasks.instance }

      before do
        # Both ends look like a TTY so the composer idle path is eligible.
        allow(Rubino::UI::BottomComposer).to receive(:active?).and_return(true)
      end

      it "reads the next line through the bottom composer (NOT the cooked fallback)" do
        expect(cmd).to receive(:read_idle_line).and_return("typed at the composer")
        expect(cmd).not_to receive(:cooked_input)

        expect(cmd.send(:next_input, input_queue)).to eq("typed at the composer")
      end

      it "still routes through the composer while a background child runs (hosts the cards)" do
        registry.reserve(subagent: "explore", prompt: "scan the repo")
        expect(cmd).to receive(:read_idle_line).and_return("typed with cards up")

        expect(cmd.send(:next_input, input_queue)).to eq("typed with cards up")
      end

      it "uses the cooked fallback when NOT a TTY" do
        allow(Rubino::UI::BottomComposer).to receive(:active?).and_return(false)
        allow(cmd).to receive(:cooked_input).and_return("plain line")
        expect(cmd).not_to receive(:read_idle_line)

        expect(cmd.send(:next_input, input_queue)).to eq("plain line")
      end
    end

    # The card region at the idle prompt is hosted by the SAME machinery a turn
    # uses (BottomComposer + the registry + the render mutex), so it is NOT gated
    # to an active turn. #paint_idle_cards renders the registry's live snapshot
    # onto whatever BottomComposer currently owns the screen, and clears it when
    # nothing runs.
    describe "#paint_idle_cards (live region at the idle prompt)" do
      let(:registry) { Rubino::Tools::BackgroundTasks.instance }
      let(:queue)    { Rubino::Interaction::InputQueue.new }
      # A non-TTY StringIO composer: #set_cards runs the real render path under
      # the mutex without touching terminal modes.
      let(:composer) do
        Rubino::UI::BottomComposer.new(
          input_queue: queue, input: StringIO.new, output: StringIO.new
        )
      end

      after { Rubino::UI::BottomComposer.current = nil }

      it "renders a card per running child onto the current composer (idle, no turn)" do
        registry.reserve(subagent: "explore", prompt: "find the bug")
        Rubino::UI::BottomComposer.current = composer

        cmd.send(:idle_cards).paint

        # The card block is live ABOVE the idle prompt — proof the region is not
        # gated to an active turn.
        expect(composer.cards).not_to be_empty
        expect(composer.cards.join).to include("explore", "running")
      end

      it "clears the card region when no child is running" do
        Rubino::UI::BottomComposer.current = composer
        composer.set_cards(["▸ sa_old · running"])

        cmd.send(:idle_cards).paint # registry empty ⇒ SubagentCards returns []

        expect(composer.cards).to eq([])
      end

      it "is a quiet no-op when no composer owns the screen" do
        registry.reserve(subagent: "explore", prompt: "x")
        Rubino::UI::BottomComposer.current = nil

        expect { cmd.send(:idle_cards).paint }.not_to raise_error
      end
    end

    # End-to-end of the idle reader against a REAL BottomComposer (non-TTY
    # StringIO so no raw termios): the user "types" a line via the composer's
    # keystroke handler and #read_idle_line returns it — with the live subagent
    # cards (F1) painted above the prompt while a child runs. Proves the region
    # renders at the idle prompt AND that a submit returns the line.
    describe "#read_idle_line (real composer)" do
      let(:input_queue) { Rubino::Interaction::InputQueue.new }
      let(:registry)    { Rubino::Tools::BackgroundTasks.instance }
      let(:output)      { StringIO.new }
      let(:fake_composer) do
        Rubino::UI::BottomComposer.new(
          input_queue: input_queue, input: StringIO.new, output: output
        )
      end

      before do
        # Avoid spawning the real raw reader thread (no TTY here); we feed
        # keystrokes synchronously through #handle_key instead.
        allow(fake_composer).to receive(:start_reader).and_return(Thread.new { nil })
        allow(Rubino::UI::BottomComposer).to receive(:new).and_return(fake_composer)
      end

      it "returns the submitted line typed at the idle prompt" do
        typist = Thread.new do
          sleep 0.05
          "hi there".each_char { |c| fake_composer.handle_key(c) }
          fake_composer.handle_key("\r")
        end

        line = cmd.send(:read_idle_line, input_queue, nil)
        typist.join

        expect(line).to eq("hi there")
      end

      it "paints the live subagent cards above the idle prompt while a child runs (F1)" do
        registry.reserve(subagent: "explore", prompt: "scan")

        typist = Thread.new do
          sleep 0.05
          "go".each_char { |c| fake_composer.handle_key(c) }
          fake_composer.handle_key("\r")
        end

        cmd.send(:read_idle_line, input_queue, nil)
        typist.join

        # The running child's collapsed row hit the composer's output.
        expect(output.string).to include("explore")
        expect(output.string).to include("running")
      end

      it "seeds a carried-over draft into the composer before reading" do
        typist = Thread.new do
          sleep 0.05
          " world".each_char { |c| fake_composer.handle_key(c) }
          fake_composer.handle_key("\r")
        end

        line = cmd.send(:read_idle_line, input_queue, "hello")
        typist.join

        expect(line).to eq("hello world")
      end

      # BH-2 wiring: a real SIGINT at the idle prompt is routed THROUGH the
      # composer (not the session-end / default handler), so a typed draft is
      # never silently discarded. With text in the buffer, the first Ctrl+C
      # CLEARS the line and the read keeps going — proven by then submitting a
      # fresh line, which returns normally. The draft is gone (cleared), the
      # session did NOT exit.
      it "idle Ctrl+C with a non-empty draft clears the line and does NOT exit" do
        typist = Thread.new do
          sleep 0.05
          "to be cleared".each_char { |c| fake_composer.handle_key(c) }
          Process.kill("INT", Process.pid) # the real idle Ctrl+C
          sleep 0.1 # let the loop drain the trap + clear
          expect(fake_composer.buffer).to eq("") # draft cleared, not lost to exit
          "after clear".each_char { |c| fake_composer.handle_key(c) }
          fake_composer.handle_key("\r")
        end

        line = cmd.send(:read_idle_line, input_queue, nil)
        typist.join

        expect(line).to eq("after clear") # read continued past the Ctrl+C
      end

      # With an EMPTY buffer, a SINGLE idle Ctrl+C must NOT exit — it arms the
      # transient hint and keeps reading. Proven by then submitting a line.
      it "idle Ctrl+C on an empty buffer does NOT exit on the first tap" do
        typist = Thread.new do
          sleep 0.05
          Process.kill("INT", Process.pid) # first (and only) Ctrl+C, empty buffer
          sleep 0.1
          "still alive".each_char { |c| fake_composer.handle_key(c) }
          fake_composer.handle_key("\r")
        end

        line = cmd.send(:read_idle_line, input_queue, nil)
        typist.join

        expect(line).to eq("still alive")
        expect(output.string).to include("press Ctrl+C again to exit")
      end

      # Two empty Ctrl+C in quick succession DO exit cleanly: #read_idle_line
      # returns nil (which #run_interactive treats as end-of-session).
      it "a double idle Ctrl+C on an empty buffer exits (returns nil)" do
        typist = Thread.new do
          sleep 0.05
          Process.kill("INT", Process.pid)
          sleep 0.1
          Process.kill("INT", Process.pid) # second tap within the window
        end

        line = cmd.send(:read_idle_line, input_queue, nil)
        typist.join

        expect(line).to be_nil # exit
      end

      # #169 — the `✓ saved to memory` class of post-turn lines: anything
      # printed while the IDLE composer is pinned must commit ABOVE the input
      # through the composer (the same StdoutProxy swap a turn gets), never raw
      # onto the terminal row the composer owns. $stdout is swapped on purpose:
      # the seam under test IS which IO the note lands in.
      # rubocop:disable RSpec/ExpectOutput
      it "routes $stdout through the composer so background notes commit above the prompt (#169)" do
        ui  = Rubino::UI::CLI.new
        old = $stdout
        idle_tty = StringIO.new
        $stdout = idle_tty
        begin
          typist = Thread.new do
            sleep 0.05
            ui.note("✓ saved to memory · 1 fact (a791dcd3)")
            "ok".each_char { |c| fake_composer.handle_key(c) }
            fake_composer.handle_key("\r")
          end

          line = cmd.send(:read_idle_line, input_queue, nil)
          typist.join

          expect(line).to eq("ok")
          # The note went through the composer's machinery...
          expect(output.string).to include("saved to memory")
          # ...not raw onto the terminal the composer owns.
          expect(idle_tty.string).not_to include("saved to memory")
          # And the real stdout is restored after the read.
          expect($stdout).to be(idle_tty)
        ensure
          $stdout = old
        end
      end
      # rubocop:enable RSpec/ExpectOutput
    end

    # #169 — the IN-TURN composer must carry the same completion + history
    # wiring as the idle one: the post-turn window (inline memory/skill jobs
    # spending aux-LLM seconds after the `↳ turn` footer) keeps the turn
    # composer on screen, and `/` + `@` must open their dropdowns there too.
    describe "#start_composer completion wiring (#169)" do
      # rubocop:disable RSpec/ExpectOutput -- start_composer swaps $stdout itself; restore it.
      it "wires the turn composer with the shared completion source and history" do
        cmd = described_class.new({})
        source  = instance_double(Rubino::UI::CompletionSource)
        history = Rubino::UI::InputHistory.new
        cmd.instance_variable_set(:@completion_source, source)
        cmd.instance_variable_set(:@input_history, history)

        composer = instance_double(Rubino::UI::BottomComposer, start: nil)
        allow(Rubino::UI::BottomComposer).to receive(:active?).and_return(true)
        expect(Rubino::UI::BottomComposer).to receive(:new)
          .with(hash_including(completion_source: source, history: history))
          .and_return(composer)

        runner = instance_double(Rubino::Agent::Runner, cancel!: nil,
                                                        session: { id: "sess-x", model: "m" })
        old = $stdout
        begin
          got, real = cmd.send(:start_composer, Rubino::Interaction::InputQueue.new, runner)
          expect(got).to be(composer)
          expect(real).to be(old)
        ensure
          $stdout = old
        end
      end
      # rubocop:enable RSpec/ExpectOutput
    end

    # Drives run_turn with a runner that blocks on a latch until the test has
    # pushed input mid-turn, proving the queued text is consumed as the NEXT
    # prompt after the turn returns.
    describe "#run_turn reader → next_input round-trip" do
      let(:runner)      { instance_double(Rubino::Agent::Runner) }
      let(:input_queue) { Rubino::Interaction::InputQueue.new }

      it "input parked during the turn becomes the next prompt" do
        # Simulate the reader: while the turn 'runs', a line lands in the queue.
        latch = Queue.new
        allow(runner).to receive(:run) do
          input_queue.push("while it worked")
          latch << :done
          "ok"
        end

        cmd.send(:run_turn, runner, "hello", ui, input_queue)
        latch.pop

        # Next boundary: queued text is consumed, no fresh read happens.
        expect(cmd).not_to receive(:cooked_input)
        expect(cmd).not_to receive(:read_idle_line)
        expect(cmd.send(:next_input, input_queue)).to eq("while it worked")
      end
    end

    # #129 end-to-end at the loop level: items the user EXPLICITLY queued
    # (Alt+Enter) during a turn that ends by an Enter-INTERRUPT must drain at
    # the boundaries that follow — the interrupting line runs first (it jumped
    # the queue), then each queued item in submission order, each as its own
    # visible turn (echo + indicator removed at commit). Nothing parks
    # invisibly behind a later send.
    describe "Enter-interrupt with explicitly queued items (#129)" do
      let(:input_queue) { Rubino::Interaction::InputQueue.new }
      let(:runner) do
        instance_double(Rubino::Agent::Runner, cancel!: nil,
                                               session: { id: "sess-x", model: "m" })
      end

      before do
        allow(Rubino::UI::BottomComposer).to receive(:active?).and_return(true)
        # Real composers over StringIO (no raw reader thread / termios).
        allow(Rubino::UI::BottomComposer).to receive(:new).and_wrap_original do |orig, **kw|
          composer = orig.call(**kw, input: StringIO.new, output: StringIO.new)
          allow(composer).to receive(:start_reader).and_return(Thread.new { nil })
          composer
        end
      end

      it "drains the queue in order across the boundaries after the interrupt" do
        runs = []
        allow(runner).to receive(:run) do |prompt, **|
          runs << prompt
          if runs.length == 1
            # Mid-turn: the user Alt+Enters AAA and BBB, then Enter-interrupts
            # with CHERRY (front of the queue + cancel).
            composer = Rubino::UI::BottomComposer.current
            "AAA".each_char { |ch| composer.handle_key(ch) }
            composer.instance_variable_set(:@input, StringIO.new("\r"))
            composer.handle_key("\e") # Alt+Enter
            "BBB".each_char { |ch| composer.handle_key(ch) }
            composer.instance_variable_set(:@input, StringIO.new("\r"))
            composer.handle_key("\e") # Alt+Enter
            "CHERRY".each_char { |ch| composer.handle_key(ch) }
            composer.handle_key("\r") # Enter-interrupt
            nil # the interrupted turn yields no answer
          else
            "ok"
          end
        end

        cmd.send(:run_turn, runner, "long essay", ui, input_queue)

        # Every parked line is VISIBLE while pending (#129): the interrupting
        # line and the queued items all carry a "⏳ queued:" indicator.
        expect(cmd.send(:pending_queued)).to eq(%w[CHERRY AAA BBB])

        # The boundaries that follow consume everything, in order, with no
        # fresh read in between — and each commit clears its indicator.
        3.times do
          line = cmd.send(:next_input, input_queue)
          cmd.send(:run_turn, runner, line, ui, input_queue)
        end

        expect(runs).to eq(["long essay", "CHERRY", "AAA", "BBB"])
        expect(cmd.send(:pending_queued)).to eq([])    # all indicators cleared
        expect(input_queue.pending?).to be(false)      # nothing left parked
      end
    end

    # The composer (and any termios mutation / $stdout swap) must be gated
    # entirely on a real TTY: piped / -q / server input is a no-op so nothing
    # touches terminal modes, no thread is spawned, and $stdout is untouched.
    describe "composer tty-gating" do
      let(:runner) { instance_double(Rubino::Agent::Runner, run: "ok") }
      let(:input_queue) { Rubino::Interaction::InputQueue.new }

      it "does not start a composer when $stdin is not a TTY" do
        allow($stdin).to receive(:tty?).and_return(false)
        expect(Thread).not_to receive(:new)

        before = $stdout
        cmd.send(:run_turn, runner, "hello", ui, input_queue)
        expect($stdout).to be(before) # $stdout not swapped for a proxy
      end

      it "start_composer returns [nil, nil] for non-TTY stdin" do
        allow($stdin).to receive(:tty?).and_return(false)
        expect(cmd.send(:start_composer, input_queue, runner)).to eq([nil, nil])
      end

      it "start_composer returns [nil, nil] when no queue is wired" do
        allow($stdin).to receive(:tty?).and_return(true)
        allow($stdout).to receive(:tty?).and_return(true)
        expect(cmd.send(:start_composer, nil, runner)).to eq([nil, nil])
      end
    end

    # BH-1 (the crash that shipped): the in-turn composer's on_interrupt lambda
    # is wired by the REAL #start_composer, where `runner` was NOT in scope (a
    # parameter of #run_turn, no @runner ivar). So the instant the user pressed
    # Enter during a turn — the documented interrupt gesture — the lambda raised
    # `NameError: undefined local variable or method 'runner'`, dumping a
    # backtrace into the chat, NOT cancelling the turn, and killing the reader.
    #
    # The existing bottom_composer specs inject their OWN on_interrupt stub, so
    # they never exercised this wiring — which is why it shipped broken. This
    # drives the REAL ChatCommand seam: build the composer via #start_composer
    # (the production wiring), then submit a line via the composer's keystroke
    # handler while a turn is active, and assert the interrupt resolves `runner`
    # and calls #cancel! with NO NameError.
    describe "interrupt-by-default wiring (BH-1)" do
      let(:runner) do
        instance_double(Rubino::Agent::Runner, run: "ok",
                                               session: { id: "sess-x", model: "m" })
      end
      let(:input_queue) { Rubino::Interaction::InputQueue.new }

      before do
        allow($stdin).to receive(:tty?).and_return(true)
        allow($stdout).to receive(:tty?).and_return(true)
        allow($stdout).to receive(:winsize).and_return([24, 80])
        # No real raw reader thread / termios: the test drives keystrokes
        # synchronously through the composer's #handle_key instead.
        allow_any_instance_of(Rubino::UI::BottomComposer)
          .to receive(:start_reader).and_return(Thread.new { nil })
        allow($stdin).to receive(:cooked!)
        allow(runner).to receive(:cancel!)
      end

      # Drive the WHOLE production seam: #run_turn builds the composer via the
      # real #start_composer and runs the runner. We stand in for the reader by
      # pressing Enter (the documented interrupt gesture) mid-turn on the SAME
      # composer #start_composer wired — so the real on_interrupt lambda fires.
      # Against the buggy code this raised `NameError: undefined local variable
      # or method 'runner'` (BH-1); after the fix it resolves `runner` and
      # cancels. NO hand-built on_interrupt stub anywhere — that is the whole
      # point (the prior specs stubbed it and never caught the crash).
      it "an Enter-during-turn submit resolves `runner` and calls cancel! (no NameError)" do
        raised = nil
        allow(runner).to receive(:run) do
          composer = Rubino::UI::BottomComposer.current
          composer.begin_turn
          "interrupt me".each_char { |ch| composer.handle_key(ch) }
          begin
            composer.handle_key("\r") # fires the REAL on_interrupt lambda
          rescue NameError => e
            raised = e # capture so the turn still unwinds and we can assert
          end
          "ok"
        end

        cmd.send(:run_turn, runner, "hello", ui, input_queue)

        expect(raised).to be_nil, "on_interrupt raised: #{raised&.message}" # BH-1
        expect(runner).to have_received(:cancel!)        # the turn was cancelled
        expect(input_queue.shift).to eq("interrupt me")  # line parked to run next
      end
    end

    # Raw mode must never leak and $stdout must be restored: even if the turn
    # raises, the ensure tears down the composer (cooked mode + real $stdout).
    describe "terminal restore on raise" do
      let(:runner) do
        instance_double(Rubino::Agent::Runner, session: { id: "sess-x", model: "m" })
      end
      let(:input_queue) { Rubino::Interaction::InputQueue.new }

      it "restores cooked mode and $stdout in ensure when the turn raises (TTY path)" do
        allow($stdin).to receive(:tty?).and_return(true)
        allow($stdout).to receive(:tty?).and_return(true)
        allow($stdout).to receive(:winsize).and_return([24, 80])
        # Stub the raw read loop so no real termios mutation happens, but the
        # reader thread is still created and must be cleaned up.
        allow($stdin).to receive(:raw).and_yield
        allow($stdin).to receive(:getc).and_return(nil) # immediate EOF, reader exits
        allow($stdin).to receive(:cooked!)
        allow($stdout).to receive(:print)
        allow($stdout).to receive(:flush)
        allow(runner).to receive(:cancel!)
        allow(runner).to receive(:run).and_raise(RuntimeError, "boom")

        before = $stdout
        expect do
          cmd.send(:run_turn, runner, "hello", ui, input_queue)
        end.to raise_error(RuntimeError, "boom")

        expect($stdin).to have_received(:cooked!).at_least(:once)
        expect($stdout).to be(before) # real $stdout restored after the swap
      end

      it "stop_composer restores cooked mode even with a nil composer" do
        allow($stdin).to receive(:tty?).and_return(true)
        allow($stdin).to receive(:cooked!)

        expect { cmd.send(:stop_composer, nil, nil) }.not_to raise_error
      end
    end
  end

  # Regression: --resume <nonexistent> used to bubble a raw SessionError /
  # AmbiguousSessionError stack trace out of Thor. Both are now rendered as
  # a clean stderr message + non-zero exit so the user sees what went wrong
  # without parsing a backtrace.
  describe "--resume error rendering" do
    it "exits with a stderr message when the session does not exist" do
      allow(Rubino::Agent::Runner).to receive(:new)
        .and_raise(Rubino::SessionError, "Session not found: deadbeef")

      expect do
        described_class.new("query" => "hi", "resume" => "deadbeef").execute
      end.to raise_error(SystemExit).and output(/Session not found/).to_stderr
    end

    it "exits with the candidate list when --resume is ambiguous" do
      err = Rubino::AmbiguousSessionError.new("feature", [
                                                { id: "11111111-aaaa-bbbb-cccc-dddddddddddd", title: "feature spike",
                                                  status: "active" },
                                                { id: "22222222-eeee-ffff-0000-111111111111", title: "feature tests",
                                                  status: "active" }
                                              ])
      allow(Rubino::Agent::Runner).to receive(:new).and_raise(err)

      expect do
        described_class.new("query" => "hi", "resume" => "feature").execute
      end.to raise_error(SystemExit).and output(/Ambiguous.*feature spike.*feature tests/m).to_stderr
    end
  end

  # Rail rubino: the prompt is a CONSTANT clean `❯ ` — no mode chip, no
  # git/workspace context. The mode/branch/skill chips live in the STATUS BAR
  # (see #build_status_line / UI::StatusBar); the red rail is prepended by the
  # composer itself, so echoes built from build_prompt stay rail-free.
  describe "#build_prompt" do
    subject(:cmd) { described_class.new({}) }

    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    def strip_ansi(s) = s.gsub(/\e\[[0-9;]*m/, "")

    it "returns the bare ❯ (no mode chip, no git/workspace context)" do
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("❯ ")
    end

    it "in a git checkout: still the bare ❯ only" do
      system("git init -q -b main && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init")
      # build_prompt no longer includes git info — that's in the startup banner
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("❯ ")
    end

    it "stays the bare ❯ in plan/yolo mode (mode rides the status bar)" do
      Rubino::Modes.set(:plan)
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("❯ ")
      Rubino::Modes.set(:yolo)
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("❯ ")
    ensure
      Rubino::Modes.set(:default)
    end

    it "the composer rail is the red ▍ brand accent" do
      expect(strip_ansi(cmd.send(:composer_rail))).to eq("▍")
    end
  end

  # Regression: rubino chat used to exit with only "Session ended." and
  # leave the user no way to find this conversation again — the session id
  # lives in SQLite, not on screen. print_resume_hint emits the exact
  # `rubino chat --resume <handle>` line, preferring the title when set.
  describe "#print_resume_hint" do
    subject(:cmd) { described_class.new({}) }

    let(:ui) { Rubino::UI::Null.new }

    it "prefers the title when one is set" do
      cmd.send(:session_resolver).print_resume_hint(ui, { id: "abc-123", title: "audit work" })
      msg = ui.messages.find { |m| m[:level] == :info && m[:message].to_s.start_with?("Resume with:") }
      expect(msg[:message]).to eq(%(Resume with: rubino chat --resume "audit work"))
    end

    it "falls back to the id when the title is missing or blank" do
      cmd.send(:session_resolver).print_resume_hint(ui, { id: "abc-123", title: nil })
      msg = ui.messages.find { |m| m[:level] == :info && m[:message].to_s.start_with?("Resume with:") }
      expect(msg[:message]).to eq("Resume with: rubino chat --resume abc-123")
    end

    it "no-ops when session is nil" do
      cmd.send(:session_resolver).print_resume_hint(ui, nil)
      expect(ui.messages.select { |m| m[:level] == :info }).to be_empty
    end
  end

  # Image input — attach an image from the terminal (@image, dropped/quoted
  # path, clipboard) so it reaches the turn's image_paths (the native vision
  # slot) instead of being sent as literal text.
  describe "image input" do
    let(:cmd) { described_class.new({}) }
    let(:ui)  { Rubino::UI::Null.new }

    around do |ex|
      Dir.mktmpdir do |dir|
        @dir = dir
        ex.run
      end
    end

    # Fixtures carry REAL magic bytes for their extension: the attachment gate
    # verifies image signatures (#158), so an extension alone no longer passes.
    def make(name)
      path = File.join(@dir, name)
      sig = { ".png" => "\x89PNG\r\n\x1a\n", ".jpg" => "\xFF\xD8\xFF", ".jpeg" => "\xFF\xD8\xFF",
              ".gif" => "GIF89a", ".webp" => "RIFF\x20\x00\x00\x00WEBPVP8 ", ".bmp" => "BM" }[File.extname(name)]
      File.binwrite(path, "#{sig}x".b)
      path
    end

    describe "#extract_images!" do
      it "moves an @image into pending_image_paths and strips it from the text" do
        img = make("pic.png")

        text = cmd.send(:image_inbox).extract_images!("look at @#{img}", ui)

        expect(text).to eq("look at")
        expect(cmd.send(:image_inbox).pending_image_paths).to eq([img])
      end

      it "keeps a non-image @file in the text and attaches nothing" do
        doc = make("notes.md")

        text = cmd.send(:image_inbox).extract_images!("read @#{doc}", ui)

        expect(text).to include("@#{doc}")
        expect(cmd.send(:image_inbox).pending_image_paths).to be_empty
      end

      it "accumulates across calls and de-dups" do
        a = make("a.png")
        b = make("b.png")

        cmd.send(:image_inbox).extract_images!("@#{a}", ui)
        cmd.send(:image_inbox).extract_images!("@#{b} @#{a}", ui)

        expect(cmd.send(:image_inbox).pending_image_paths).to eq([a, b])
      end

      # #225: a line with text AND an @image sends BOTH on THIS turn (the cleaned
      # text is non-empty), so the indicator must say so — the old "sent with
      # your next message" wording contradicted the actual disposition.
      it "says 'attached to this message' when the line ALSO carries text (#225)" do
        img = make("pic.png")

        cmd.send(:image_inbox).extract_images!("@#{img} what color is this?", ui)

        statuses = ui.messages.select { |m| m[:level] == :status }.map { |m| m[:message] }
        expect(statuses).to include("1 image attached — attached to this message.")
        expect(statuses).not_to include(a_string_matching(/sent with your next message/))
      end

      it "keeps the 'sent with your next message' staging wording for an image-only line (#225)" do
        img = make("only.png")

        cmd.send(:image_inbox).extract_images!("@#{img}", ui)

        statuses = ui.messages.select { |m| m[:level] == :status }.map { |m| m[:message] }
        expect(statuses)
          .to include("1 image attached — sent with your next message (/clear-images to drop).")
      end
    end

    # `chat --image/-i` without -q must STAGE in interactive mode (#160): the
    # flag was consumed only by the one-shot path and silently dropped here,
    # though docs promise it stages and /clear-images covers it.
    describe "#stage_flag_images (#160)" do
      it "seeds the pending inbox from --image flag paths" do
        img = make("flagged.png")
        cmd = described_class.new("image" => [img])

        cmd.send(:stage_flag_images, ui)

        expect(cmd.send(:image_inbox).pending_image_paths).to eq([img])
      end

      it "stages nothing and stays silent when no --image flag was given" do
        cmd = described_class.new({})

        cmd.send(:stage_flag_images, ui)

        expect(cmd.send(:image_inbox).pending_image_paths).to be_empty
        expect(ui.messages).to be_empty
      end

      it "warns and skips a flag path that is not a readable image" do
        cmd = described_class.new("image" => [File.join(@dir, "missing.png")])

        cmd.send(:stage_flag_images, ui)

        expect(cmd.send(:image_inbox).pending_image_paths).to be_empty
        expect(ui.messages.map { |m| m[:level] }).to include(:warning)
      end

      it "rejects a content-spoofed flag path through the shared gate (#158)" do
        spoof = File.join(@dir, "fake.png")
        File.write(spoof, "this is not an image\n")
        cmd = described_class.new("image" => [spoof])

        cmd.send(:stage_flag_images, ui)

        expect(cmd.send(:image_inbox).pending_image_paths).to be_empty
        expect(ui.messages.map { |m| m[:level] }).to include(:warning)
      end

      it "is covered by /clear-images like every other staging surface" do
        img = make("flagged.png")
        cmd = described_class.new("image" => [img])
        cmd.send(:stage_flag_images, ui)

        cmd.send(:image_inbox).handle_image_command("/clear-images", ui)

        expect(cmd.send(:image_inbox).pending_image_paths).to be_empty
      end
    end

    describe "#handle_image_command" do
      it "/clear-images drops all pending attachments and returns true" do
        cmd.send(:image_inbox).extract_images!("@#{make("x.png")}", ui)
        expect(cmd.send(:image_inbox).pending_image_paths).not_to be_empty

        expect(cmd.send(:image_inbox).handle_image_command("/clear-images", ui)).to be(true)
        expect(cmd.send(:image_inbox).pending_image_paths).to be_empty
      end

      it "/paste attaches a clipboard image when capture succeeds" do
        clip = make("clip.png")
        allow(Rubino::Interaction::ClipboardImage).to receive(:save_to_tempfile).and_return(clip)

        expect(cmd.send(:image_inbox).handle_image_command("/paste", ui)).to be(true)
        expect(cmd.send(:image_inbox).pending_image_paths).to eq([clip])
      end

      it "/paste warns (and attaches nothing) when capture fails" do
        allow(Rubino::Interaction::ClipboardImage).to receive(:save_to_tempfile).and_return(nil)

        cmd.send(:image_inbox).handle_image_command("/paste", ui)

        expect(cmd.send(:image_inbox).pending_image_paths).to be_empty
        expect(ui.messages.map { |m| m[:level] }).to include(:warning)
      end

      it "returns false for a non-image command (falls through to the dispatcher)" do
        expect(cmd.send(:image_inbox).handle_image_command("/help", ui)).to be(false)
      end
    end

    # Headless / scripted attachment: `-q` (and `prompt` / `chat "..."`) must be
    # able to attach an image too, not just the interactive REPL. Both @image
    # tokens in the prompt AND explicit --image PATH flags are routed to the
    # native vision slot (image_paths) and the tokens stripped from the text.
    describe "#run_oneshot → image_paths (headless)" do
      it "honours an @image token in the one-shot prompt" do
        img = make("shot.png")
        described_class.new("query" => "extract the number from @#{img}").execute
        expect(fake_runner).to have_received(:run!).with(
          "extract the number from", image_paths: [img]
        )
      end

      it "honours --image flag paths and merges them ahead of in-line tokens" do
        a = make("flag.png")
        b = make("inline.png")
        described_class.new("query" => "compare @#{b}", "image" => [a]).execute
        expect(fake_runner).to have_received(:run!).with(
          "compare", image_paths: [a, b]
        )
      end

      it "passes empty image_paths for a plain prompt" do
        described_class.new("query" => "just text").execute
        expect(fake_runner).to have_received(:run!).with("just text", image_paths: [])
      end

      it "skips (and reports) a --image path that is not a readable image" do
        doc = make("notes.txt")
        expect do
          described_class.new("query" => "hi", "image" => [doc]).execute
        end.to output(/ignoring --image.*not a readable image/).to_stderr
        expect(fake_runner).to have_received(:run!).with("hi", image_paths: [])
      end
    end

    describe "#run_turn → image_paths" do
      let(:runner) { instance_double(Rubino::Agent::Runner) }

      it "passes pending images to runner.run and clears them after the turn" do
        img = make("send.png")
        cmd.send(:image_inbox).extract_images!("@#{img}", ui)
        allow(runner).to receive(:run)

        cmd.send(:run_turn, runner, "describe it", ui)

        expect(runner).to have_received(:run).with(
          "describe it", image_paths: [img], input_queue: nil
        )
        # Sent exactly once: the next turn starts with no attachments.
        expect(cmd.send(:image_inbox).pending_image_paths).to be_empty
      end

      it "passes an empty image_paths when nothing is attached" do
        allow(runner).to receive(:run)

        cmd.send(:run_turn, runner, "hi", ui)

        expect(runner).to have_received(:run).with("hi", image_paths: [], input_queue: nil)
      end
    end

    # Regression #98: CLI image attachments must pass the SAME secure-by-default
    # attachment gate as the server/run path. An oversize/spoofed image used to
    # ship to the provider unchecked and burn 5 retries (~80s) on the permanent
    # rejection; now it is a clean one-line stderr error BEFORE any model call.
    describe "attachment policy gate (#98)" do
      def make_spoof(name)
        path = File.join(@dir, name)
        File.binwrite(path, "PK\x03\x04\x14\x00\x00\x00\x08\x00#{" " * 50}")
        path
      end

      it "one-shot @image that violates the policy fails fast with a clean error" do
        spoof = make_spoof("fake.png")

        expect do
          expect { described_class.new("query" => "hi @#{spoof}").execute }.to raise_error(SystemExit)
        end.to output(/rubino: .*not a valid image/).to_stderr

        expect(fake_runner).not_to have_received(:run!)
      end

      it "one-shot --image flag path that violates the policy fails fast" do
        spoof = make_spoof("flag.png")

        expect do
          expect { described_class.new("query" => "hi", "image" => [spoof]).execute }
            .to raise_error(SystemExit)
        end.to output(/rubino: --image .*not a valid image/).to_stderr

        expect(fake_runner).not_to have_received(:run!)
      end

      it "interactive extract_images! warns and drops a rejected candidate" do
        spoof = make_spoof("bad.png")

        text = cmd.send(:image_inbox).extract_images!("look @#{spoof}", ui)

        expect(text).to eq("look")
        expect(cmd.send(:image_inbox).pending_image_paths).to be_empty
        warning = ui.messages.find { |m| m[:level] == :warning }
        expect(warning[:message]).to include("bad.png").and include("not a valid image")
      end

      it "/paste runs the clipboard capture through the same gate" do
        spoof = make_spoof("clip.png")
        allow(Rubino::Interaction::ClipboardImage).to receive(:save_to_tempfile).and_return(spoof)

        cmd.send(:image_inbox).handle_image_command("/paste", ui)

        expect(cmd.send(:image_inbox).pending_image_paths).to be_empty
        expect(ui.messages.map { |m| m[:level] }).to include(:warning)
      end
    end

    # Regression #100: an image-only line used to auto-submit a turn (with a
    # default question), consuming the attachment on the same Enter — so the
    # promised "sent with your next message (/clear-images to drop)" window
    # never existed for @image/dropped-path attachments. It now STAGES the
    # image; /clear-images is reachable and the next real message carries it.
    describe "image-only line stages the attachment (#100)" do
      before do
        allow(Rubino::UI::BottomComposer).to receive(:active?).and_return(false)
        allow(Rubino::Commands::Executor).to receive(:welcome)
        allow(fake_runner).to receive_messages(session: { id: "sess-100", title: nil }, end_session!: nil)
        allow(cmd).to receive_messages(setup_workspace_and_trust!: nil, git_context: nil,
                                       redirect_logger_to_file: nil)
      end

      def feed(*lines)
        allow($stdin).to receive(:gets).and_return(*lines.map { |l| "#{l}\n" }, nil)
      end

      it "does not run a turn for an image-only line, so /clear-images is reachable" do
        img = make("solo.png")
        feed("@#{img}", "/clear-images", "exit")

        expect { cmd.send(:run_interactive) }.to output.to_stdout

        expect(fake_runner).not_to have_received(:run)
        expect(cmd.send(:image_inbox).pending_image_paths).to be_empty
        cleared = null_ui.messages.find { |m| m[:message].to_s.include?("Cleared 1 attached image") }
        expect(cleared).not_to be_nil
      end

      it "sends the staged image with the next message" do
        img = make("solo.png")
        feed("@#{img}", "describe it", "exit")

        expect { cmd.send(:run_interactive) }.to output.to_stdout

        expect(fake_runner).to have_received(:run).with(
          "describe it", image_paths: [img], input_queue: kind_of(Rubino::Interaction::InputQueue)
        )
      end
    end

    # Regression #99: structured llm.retry JSON lines used to land on STDOUT in
    # one-shot mode, corrupting the pipeable answer. The one-shot path now
    # routes the logger to stderr for the duration of the run.
    describe "one-shot structured logs go to stderr (#99)" do
      it "keeps stdout clean and emits log lines on stderr" do
        allow(fake_runner).to receive(:run!) do
          Rubino.logger.warn(event: "llm.retry", attempt: 1, sleep: 2)
          "ANSWER"
        end

        expect do
          expect { described_class.new("query" => "ping").execute }
            .to output("ANSWER\n").to_stdout
        end.to output(/llm\.retry/).to_stderr
      end

      it "restores the logger sink after the run" do
        sink = StringIO.new
        prev = Rubino.logger.reopen(sink)
        begin
          described_class.new("query" => "ping").execute
          Rubino.logger.warn(event: "after.oneshot")
          expect(sink.string).to include("after.oneshot")
        ensure
          Rubino.logger.reopen(prev)
        end
      end
    end

    # #101: a deterministic status line before an upload-carrying request, so a
    # multi-MB attachment doesn't look like a freeze in non-interactive mode.
    describe "sending-image status line (#101)" do
      it "announces 'sending image (N MB)…' on stderr when attachments are present" do
        img = make("pic.png")

        expect do
          described_class.new("query" => "see @#{img}").execute
        end.to output(/sending image \(\d+(\.\d+)? MB\)…/).to_stderr
      end

      it "prints nothing extra for a plain text prompt" do
        expect do
          described_class.new("query" => "just text").execute
        end.not_to output(/sending/).to_stderr
      end
    end
  end

  # Regression: cancel! used to be a no-op when called before the first
  # run() because @cancel_token was nil until run() built it. A Ctrl+C in
  # the microsecond between Signal.trap install and runner.run was lost,
  # and the next turn started normally — user pressed cancel, saw nothing
  # happen, and the model ran anyway.
  describe "Runner cancel_token lifecycle" do
    it "honours a cancel! that arrived before the first run" do
      # Top-level before stubs Runner.new to return fake_runner; this test
      # needs the real class to verify the cancel_token lifecycle.
      allow(Rubino::Agent::Runner).to receive(:new).and_call_original

      repo = Rubino::Session::Repository.new
      session = repo.create(source: "spec", model: "test", provider: "test")
      runner = Rubino::Agent::Runner.new(session_id: session[:id], ui: null_ui)

      runner.cancel!
      token = runner.instance_variable_get(:@cancel_token)
      expect(token).not_to be_nil
      expect(token.cancelled?).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # #93 — first-run credential gate: no silent-empty failure.
  # ---------------------------------------------------------------------------
  describe "first-run credential gate (#93)" do
    context "when no usable model/key is configured (non-interactive)" do
      before do
        allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(false)
        allow(Rubino::LLM::CredentialCheck).to receive(:missing_key_message)
          .and_return("No API key configured for provider 'openai' (model openai/gpt-4.1). run `rubino setup`")
      end

      it "surfaces a clear actionable error to stderr and exits non-zero (no silent empty success)" do
        expect do
          described_class.new("query" => "hi").execute
        end.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output(/No API key configured.*rubino setup/m).to_stderr
      end

      it "never reaches the model runner" do
        expect(fake_runner).not_to receive(:run!)
        expect { described_class.new("query" => "hi").execute }.to raise_error(SystemExit)
      end
    end

    context "when a model/key IS configured (already set-up user)" do
      before do
        allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(true)
      end

      it "is unaffected: the one-shot turn runs and prints the response" do
        expect { described_class.new("query" => "hi").execute }
          .to output("RESPONSE_TEXT\n").to_stdout
      end
    end

    context "with an explicit --model/--provider override" do
      it "bypasses the config preflight (user is steering deliberately)" do
        allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(false)
        expect(Rubino::LLM::CredentialCheck).not_to receive(:missing_key_message)

        expect { described_class.new("query" => "hi", "provider" => "fake").execute }
          .to output("RESPONSE_TEXT\n").to_stdout
      end
    end

    context "runtime model failure on the one-shot path" do
      before do
        allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(true)
      end

      it "surfaces the error to stderr and exits non-zero instead of a silent empty exit-0" do
        allow(fake_runner).to receive(:run!)
          .and_raise(Rubino::Error.new("Authentication failed (401). Token may have expired"))

        expect do
          described_class.new("query" => "hi").execute
        end.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output(/Authentication failed/).to_stderr
      end
    end
  end

  # #125: during an interactive session the structured logger must NOT write to
  # the terminal $stdout the raw-mode TUI renders into. #redirect_logger_to_file
  # reopens the logger onto a file in the logs dir; #restore_logger puts it back.
  describe "interactive logger routing (#125)" do
    around do |example|
      Dir.mktmpdir do |dir|
        @logs_dir = dir
        example.run
      end
    end

    before do
      allow(Rubino.configuration).to receive(:dig).and_call_original
      allow(Rubino.configuration).to receive(:dig).with("paths", "logs").and_return(@logs_dir)
      Rubino.logger = Rubino::Logger.new(io: $stdout, format: "json")
    end

    after { Rubino.logger = Rubino::Logger.new }

    it "redirects the logger to a file so JSON lines never reach $stdout, then logs land in the file" do
      cmd = described_class.new({})

      out = capture_stdout do
        prev = cmd.send(:redirect_logger_to_file)
        expect(prev).not_to be_nil
        Rubino.logger.warn(event: "llm.stream.partial_interrupted", error: "TCP blip")
        cmd.send(:restore_logger, prev)
      end

      expect(out).to eq("") # no JSON leaked into the TUI's stdout

      log = File.read(File.join(@logs_dir, "rubino.log"))
      expect(log).to include("llm.stream.partial_interrupted")
    end

    it "restores the logger sink after the session" do
      sink = StringIO.new
      Rubino.logger = Rubino::Logger.new(io: sink, format: "json")
      cmd  = described_class.new({})

      prev = cmd.send(:redirect_logger_to_file)
      expect(prev).to be(sink) # captured the original sink
      cmd.send(:restore_logger, prev)

      Rubino.logger.info(event: "after.restore")
      expect(sink.string).to include("after.restore") # back on the original sink
    end
  end

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end
end
