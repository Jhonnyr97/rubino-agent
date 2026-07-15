# frozen_string_literal: true

RSpec.describe Rubino::Agent::ToolExecutor do
  subject(:executor) do
    described_class.new(registry: registry, approval_policy: policy, ui: ui,
                        config: config, tool_call_repository: repo)
  end

  let(:tool) do
    Class.new(Rubino::Tools::Base) do
      def name = "fake_tool"
      def description = "fake"
      def input_schema = { type: "object" }
      def risk_level = :low
      attr_writer :output

      def call(_args)
        @output.nil? ? "ok" : @output
      end
    end.new
  end

  let(:registry) { double("Registry", find: tool) }
  let(:policy)   { double("ApprovalPolicy") }
  let(:ui)       { double("UI", confirm: true, interactive?: true) }
  let(:repo)     { double("Repo", record: true) }
  let(:config)   { Rubino.configuration }

  # Overflowing output spills the full text to <home>/tool-results/<id>.txt;
  # sandbox home so tests don't write into the real ~/.rubino.
  let(:spill_home) { Dir.mktmpdir("spill_home") }

  after { FileUtils.rm_rf(spill_home) }
  before { allow(Rubino).to receive(:home_path).and_return(spill_home) }

  # Claude-aligned widen-on-approval: a structured write routed to :ask because
  # its target is outside the workspace gets the target's directory added to the
  # roots once the human approves (or under yolo), so the tool's own guard + the
  # OS write-jail let it land instead of the dead-end refusal.
  describe "widen-on-approval for out-of-workspace writes" do
    it "adds each widen dir to the workspace after approval, before running" do
      dir = Dir.mktmpdir("widen")
      allow(policy).to receive(:decide).and_return(:ask)
      allow(policy).to receive(:last_ask_reason).and_return(:outside_workspace)
      allow(policy).to receive(:workspace_widen_dirs).and_return([dir])
      allow(ui).to receive(:warning)
      expect(Rubino::Workspace).to receive(:add).with(dir)
      executor.execute(name: "fake_tool", arguments: { "file_path" => "x" }, call_id: "c1")
    ensure
      FileUtils.rm_rf(dir)
    end

    it "does not widen when the policy reports no dirs (in-workspace write)" do
      allow(policy).to receive(:decide).and_return(:allow)
      allow(policy).to receive(:workspace_widen_dirs).and_return([])
      expect(Rubino::Workspace).not_to receive(:add)
      executor.execute(name: "fake_tool", arguments: { "file_path" => "x" }, call_id: "c1")
    end

    it "never widens on a denied out-of-workspace write" do
      allow(policy).to receive(:decide).and_return(:ask)
      allow(policy).to receive(:last_ask_reason).and_return(:outside_workspace)
      allow(policy).to receive(:workspace_widen_dirs).and_return(["/somewhere/outside"])
      allow(ui).to receive(:confirm).and_return(false)
      expect(Rubino::Workspace).not_to receive(:add)
      executor.execute(name: "fake_tool", arguments: { "file_path" => "x" }, call_id: "c1")
    end
  end

  describe "approval decisions" do
    it "records the call and runs the tool when policy allows" do
      allow(policy).to receive(:decide).and_return(:allow)
      expect(repo).to receive(:record).with(hash_including(status: "completed"))
      result = executor.execute(name: "fake_tool", arguments: { "x" => 1 }, call_id: "c1")
      expect(result.output).to eq("ok")
    end

    # #262: the tool_calls audit table has a NOT-NULL session_id FK. The Result
    # is built deep in the pipeline with no session context, so the executor
    # stamps its session id onto it just before the record — otherwise every
    # insert violated the constraint and was swallowed, leaving the table empty.
    it "stamps the executor's session_id onto the recorded Result (#262)" do
      scoped = described_class.new(registry: registry, approval_policy: policy, ui: ui,
                                   config: config, tool_call_repository: repo, session_id: "sess-42")
      allow(policy).to receive(:decide).and_return(:allow)
      expect(repo).to receive(:record) do |**kw|
        expect(kw[:result].session_id).to eq("sess-42")
      end
      scoped.execute(name: "fake_tool", arguments: { "x" => 1 }, call_id: "c1")
    end

    it "audits denied calls when policy returns :deny (issue #7, #17)" do
      allow(policy).to receive(:decide).and_return(:deny)
      expect(repo).to receive(:record).with(hash_including(status: "denied", error: "policy-denied"))
      result = executor.execute(name: "fake_tool", arguments: {}, call_id: "c2")
      expect(result.denied?).to be true
    end

    it "audits denied calls when the user rejects an :ask prompt" do
      allow(policy).to receive(:decide).and_return(:ask)
      allow(ui).to receive(:confirm).and_return(false)
      expect(repo).to receive(:record).with(hash_including(status: "denied", error: "user-denied"))
      result = executor.execute(name: "fake_tool", arguments: {}, call_id: "c3")
      expect(result.denied?).to be true
    end

    # #143: the model-facing output must say WHO/WHAT denied. Only a real
    # human rejection reads "denied by user"; a policy deny threads the
    # policy's recorded reason through Tools::Result.denied.
    describe "denial messages name who denied (#143)" do
      it "a policy deny carries the reason-specific message, not 'denied by user'" do
        allow(policy).to receive_messages(decide: :deny, last_deny_reason: :doom_loop)
        result = executor.execute(name: "fake_tool", arguments: {}, call_id: "c10")
        expect(result.output).to include("doom-loop guard")
        expect(result.output).not_to include("denied by user")
      end

      it "a policy deny without an exposed reason still reads as policy, not user" do
        allow(policy).to receive(:decide).and_return(:deny) # no last_deny_reason on the double
        result = executor.execute(name: "fake_tool", arguments: {}, call_id: "c11")
        expect(result.output).to include("Tool execution denied by policy (not by the user).")
        expect(result.output).not_to include("denied by user")
      end

      it "a user rejection still reads 'denied by user'" do
        allow(policy).to receive(:decide).and_return(:ask)
        allow(ui).to receive(:confirm).and_return(false)
        result = executor.execute(name: "fake_tool", arguments: {}, call_id: "c12")
        expect(result.output).to include("Tool execution denied by user.")
      end

      # A policy deny now SURFACES as a card (started + a denied result carrying
      # the reason label) instead of being counter-only, so the operator sees
      # which command was auto-refused and why.
      it "emits a started + labelled-denied card for a policy deny" do
        card_ui = double("UI", confirm: true, interactive?: true)
        allow(card_ui).to receive(:tool_started)
        finished = nil
        allow(card_ui).to receive(:tool_finished) { |_name, result:| finished = result }
        ex = described_class.new(registry: registry, approval_policy: policy, ui: card_ui,
                                 config: config, tool_call_repository: repo)
        allow(policy).to receive_messages(decide: :deny, last_deny_reason: :hardline)

        ex.execute(name: "fake_tool", arguments: { "command" => "rm -rf /" }, call_id: "cX")

        expect(card_ui).to have_received(:tool_started)
        expect(finished).to be_denied
        expect(finished.label).to eq("hardline")
      end
    end

    it "passes the arguments to the approval policy so patterns can match (#17)" do
      allow(policy).to receive(:decide).and_return(:allow)
      expect(policy).to receive(:decide).with(tool, arguments: { x: 1 })
      executor.execute(name: "fake_tool", arguments: { "x" => 1 }, call_id: "c4")
    end

    # #260: headless FAIL-CLOSED. A tool the policy wants to ASK about, run in a
    # non-interactive session (no human to answer), must be DENIED — never
    # auto-run (the old UI::Null#confirm → true RCE foot-gun) and never blocked
    # on a prompt no one can answer (the hang).
    describe "headless fail-closed on :ask (#260)" do
      let(:ui) { double("UI", confirm: true, interactive?: false, warning: nil) }

      it "blocks the tool without ever calling #confirm" do
        allow(policy).to receive(:decide).and_return(:ask)
        expect(ui).not_to receive(:confirm)
        result = executor.execute(name: "fake_tool", arguments: { "command" => "touch x" }, call_id: "n1")
        expect(result.denied?).to be true
      end

      it "does NOT run the tool" do
        allow(policy).to receive(:decide).and_return(:ask)
        expect(tool).not_to receive(:call)
        executor.execute(name: "fake_tool", arguments: {}, call_id: "n2")
      end

      it "surfaces a single-line block message to the UI" do
        allow(policy).to receive(:decide).and_return(:ask)
        expect(ui).to receive(:warning).with(/\Ablocked: fake_tool.*needs approval but no interactive session/)
        executor.execute(name: "fake_tool", arguments: { "command" => "touch x" }, call_id: "n3")
      end

      it "records the denial as noninteractive-blocked and sets blocked_for_approval?" do
        allow(policy).to receive(:decide).and_return(:ask)
        expect(repo).to receive(:record).with(hash_including(status: "denied", error: "noninteractive-blocked"))
        executor.execute(name: "fake_tool", arguments: {}, call_id: "n4")
        expect(executor.blocked_for_approval?).to be true
      end

      it "gives the model a reason that names the missing session, not the user" do
        allow(policy).to receive(:decide).and_return(:ask)
        result = executor.execute(name: "fake_tool", arguments: {}, call_id: "n5")
        expect(result.output).to include("no interactive session")
        expect(result.output).not_to include("denied by user")
      end

      it "does NOT flag a block when the policy allows the tool (no regression for allowlisted)" do
        allow(policy).to receive(:decide).and_return(:allow)
        executor.execute(name: "fake_tool", arguments: {}, call_id: "n6")
        expect(executor.blocked_for_approval?).to be false
      end
    end

    # #86: a SUBAGENT is non-interactive LOCALLY (no terminal of its own) but CAN
    # escalate an approval to the PARENT. Its UI is a per-sub UI::CLI WITH a wired
    # approval handler, so #interactive? is TRUE — the :ask must route to that
    # handler (park → parent card → run on grant), NOT to the headless
    # :noninteractive fail-closed block a real no-parent one-shot gets.
    describe "subagent :ask escalates to the parent instead of the noninteractive block (#86)" do
      let(:registry_bg) { Rubino::Tools::BackgroundTasks.instance }
      let(:entry)       { registry_bg.reserve(subagent: "explore", prompt: "x") }
      # The exact handler TaskTool wires onto a background child's per-sub CLI:
      # parks the entry on a per-entry ApprovalGate, returns the human's decision.
      let(:approve)     { Rubino::Tools::TaskTool.new.send(:approval_handler_for, entry) }
      let(:ui) do
        Rubino::UI::CLI.new(agent_id: entry.id, approval_handler: approve)
      end

      before do
        allow(policy).to receive(:decide).and_return(:ask)
        allow(repo).to receive(:record)
        # No real CLI live region under test: a Null root makes the handler's
        # parent-card surface / repaint / notifier calls all natural no-ops
        # (they guard on is_a?(UI::CLI) / respond_to?), so the escalation path
        # runs without a terminal. The escalation gate itself is unaffected.
        Rubino.ui = Rubino::UI::Null.new
      end

      after { Rubino.ui = nil }

      it "PARKS the entry on :needs_approval and runs the tool when the parent grants" do
        # interactive? is TRUE for a subagent WITH an escalation gate (NOT a
        # headless one-shot) — the precise signal the noninteractive block keys on.
        expect(ui.interactive?).to be(true)

        result = nil
        th = Thread.new do
          result = executor.execute(name: "fake_tool",
                                    arguments: { "command" => "touch x" }, call_id: "esc1")
        end

        # The :ask routed to the escalation gate: the entry is now awaiting the
        # parent's decision — NOT denied with the noninteractive block.
        deadline = Time.now + 2.0
        sleep 0.01 until registry_bg.find(entry.id)&.status == :needs_approval || Time.now > deadline
        expect(registry_bg.find(entry.id).status).to eq(:needs_approval)
        expect(th).to be_alive # the child tool is parked, not failed

        parked = registry_bg.find(entry.id)
        parked.approval_gate.decide(parked.approval_id, true)
        th.join(2)

        expect(result.success?).to be(true)
        expect(result.output).to eq("ok") # the tool actually ran on grant
        expect(executor.blocked_for_approval?).to be(false) # never took the noninteractive path
      end

      it "fails the tool CLEANLY (denied by user, not noninteractive) when the parent denies" do
        result = nil
        th = Thread.new do
          result = executor.execute(name: "fake_tool",
                                    arguments: { "command" => "touch x" }, call_id: "esc2")
        end
        deadline = Time.now + 2.0
        sleep 0.01 until registry_bg.find(entry.id)&.status == :needs_approval || Time.now > deadline

        parked = registry_bg.find(entry.id)
        parked.approval_gate.decide(parked.approval_id, false)
        th.join(2)

        expect(result.denied?).to be(true)
        expect(result.output).to include("denied by user")
        expect(result.output).not_to include("no interactive session")
        expect(executor.blocked_for_approval?).to be(false)
      end
    end
  end

  # #335b: a cancel that flips while a previous tool was running (or during the
  # thinking phase) must halt the turn at the NEXT tool boundary — on the
  # streaming path ruby_llm dispatches tools mid-stream through here, far below
  # the loop's per-iteration #check!, so without a checkpoint in #execute the
  # interrupt isn't observed and one more tool fires after the user hit Enter.
  describe "cancellation checkpoint before a tool runs (#335b)" do
    subject(:cancellable) do
      described_class.new(registry: registry, approval_policy: policy, ui: ui,
                          config: config, tool_call_repository: repo, cancel_token: token)
    end

    let(:token) { Rubino::Interaction::CancelToken.new }

    it "raises Interrupted and never runs the tool when the token is cancelled" do
      allow(policy).to receive(:decide).and_return(:allow)
      token.cancel!
      expect(tool).not_to receive(:call)
      expect do
        cancellable.execute(name: "fake_tool", arguments: { "x" => 1 }, call_id: "c1")
      end.to raise_error(Rubino::Interrupted)
    end

    it "runs the tool normally when the token is not cancelled" do
      allow(policy).to receive(:decide).and_return(:allow)
      allow(repo).to receive(:record)
      result = cancellable.execute(name: "fake_tool", arguments: { "x" => 1 }, call_id: "c1")
      expect(result.output).to eq("ok")
    end

    # #41 — a Rubino::Interrupted raised from WITHIN a tool (the cancel landed
    # mid-call, after the pre-tool checkpoint) is a StandardError, so the
    # run_tool rescue used to fold it into a `status: "failed"` Result. The loop
    # then continued and sent a malformed continuation (rejected as "invalid
    # params"). It must re-raise so the cancel path ends the turn cleanly.
    it "re-raises an Interrupted raised mid-call instead of recording a failed result" do
      allow(policy).to receive(:decide).and_return(:allow)
      allow(tool).to receive(:call).and_raise(Rubino::Interrupted)
      expect(repo).not_to receive(:record).with(hash_including(status: "failed"))
      expect do
        cancellable.execute(name: "fake_tool", arguments: { "x" => 1 }, call_id: "c1")
      end.to raise_error(Rubino::Interrupted)
    end
  end

  # Regression: arguments.inspect on multi-line values collapsed everything
  # into one giant line, the terminal cropped at 80 columns, and the user
  # approved a "ls -la" they could see while the model had actually sent
  # `ls -la; rm -rf $HOME`. Each arg is now laid out on its own line and
  # multi-line values get a "[… N more line(s)]" tag so silence can't hide
  # the tail.
  # Regression: --yolo (approvals.mode: "skip") used to silently auto-run
  # every tool. The user pressed Enter and the model could fire shell or
  # write without any visual signal. Now risky tools emit a "⚡ yolo:"
  # warning right before execution so silence can't mask intent.
  describe "yolo mode visibility" do
    before do
      allow(policy).to receive(:decide).and_return(:allow)
      # The general stub goes FIRST so the specific one overrides it for
      # ("approvals", "mode"); RSpec resolves the most-specific match last.
      allow(config).to receive(:dig).and_call_original
      allow(config).to receive(:dig).with("approvals", "mode").and_return("skip")
    end

    it "warns before running a risky tool in skip mode" do
      # fake_tool defined at the top of this file is :low risk; build a :high one
      risky = Class.new(Rubino::Tools::Base) do
        def name = "shell"
        def description = "x"
        def input_schema = {}
        def risk_level = :high
        def risky? = true
        def call(_) = "out"
      end.new
      allow(registry).to receive(:find).and_return(risky)

      expect(ui).to receive(:warning).with(a_string_matching(/yolo.*shell.*ls/))
      executor.execute(name: "shell", arguments: { "command" => "ls" }, call_id: "c1")
    end

    it "stays quiet for low-risk tools in skip mode" do
      expect(ui).not_to receive(:warning)
      executor.execute(name: "fake_tool", arguments: {}, call_id: "c2")
    end
  end

  # Regression: a streaming tool (ShellTool) emits its stdout line by line via
  # #tool_chunk AND returns a `body:` block (Util::Output.preview of the same
  # stdout). The executor used to render BOTH, so every output line appeared
  # twice in the timeline. When the tool streamed, the body must be suppressed.
  describe "streamed tool output is not also rendered as a body" do
    subject(:streaming_executor) do
      described_class.new(registry: streaming_registry, approval_policy: policy,
                          ui: streaming_ui, config: config, tool_call_repository: repo)
    end

    let(:streaming_tool) do
      Class.new(Rubino::Tools::Base) do
        def name = "fake_stream"
        def description = "fake"
        def input_schema = { type: "object" }
        def risk_level = :low

        def call(_args)
          emit_chunk("13\n")
          { output: "13\n", body: "13", body_kind: :plain }
        end
      end.new
    end

    let(:streaming_registry) { double("Registry", find: streaming_tool) }
    let(:streaming_ui) do
      double("UI", confirm: true, tool_started: nil, tool_finished: nil, tool_chunk: nil, tool_body: nil)
    end

    before { allow(policy).to receive(:decide).and_return(:allow) }

    it "streams chunks but does NOT re-render the body for a streaming tool" do
      expect(streaming_ui).to receive(:tool_chunk).with("fake_stream", "13\n", kind: :plain)
      expect(streaming_ui).not_to receive(:tool_body)
      streaming_executor.execute(name: "fake_stream", arguments: {}, call_id: "s1")
    end

    it "still renders the body for a NON-streaming tool that returns one" do
      non_streaming = Class.new(Rubino::Tools::Base) do
        def name = "fake_body"
        def description = "fake"
        def input_schema = { type: "object" }
        def risk_level = :low
        def call(_args) = { output: "x", body: "preview", body_kind: :plain }
      end.new
      allow(streaming_registry).to receive(:find).and_return(non_streaming)
      expect(streaming_ui).to receive(:tool_body).with("preview", kind: :plain)
      expect(streaming_ui).not_to receive(:tool_chunk)
      streaming_executor.execute(name: "fake_body", arguments: {}, call_id: "s2")
    end
  end

  describe "tool.progress heartbeats on the bus (SSE idle watchdog)" do
    # A long, silent tool that emits several stream chunks. In API mode these
    # must reach the event bus as TOOL_PROGRESS so the SSE stream isn't silent
    # for minutes and the idle watchdog doesn't reap a busy-but-quiet run.
    subject(:bus_executor) do
      described_class.new(registry: bus_reg, approval_policy: policy,
                          ui: bus_ui, config: config, tool_call_repository: repo,
                          event_bus: bus)
    end

    let(:chatty_tool) do
      Class.new(Rubino::Tools::Base) do
        def name = "chatty"
        def description = "fake"
        def input_schema = { type: "object" }
        def risk_level = :low

        def call(_args)
          5.times { |i| emit_chunk("chunk #{i}\n") }
          "done"
        end
      end.new
    end
    let(:bus)     { Rubino::Interaction::EventBus.new }
    let(:bus_reg) { double("Registry", find: chatty_tool) }
    let(:bus_ui)  { double("UI", confirm: true, tool_started: nil, tool_finished: nil) }

    before { allow(policy).to receive(:decide).and_return(:allow) }

    it "emits TOOL_PROGRESS on the bus even when the UI has no tool_chunk sink" do
      progress = []
      bus.on(Rubino::Interaction::Events::TOOL_PROGRESS) { |p| progress << p }
      bus_executor.execute(name: "chatty", arguments: {}, call_id: "p1")
      # Throttled to one per interval; the first chunk always emits, the rest
      # fall inside the window. At minimum the first heartbeat must flow.
      expect(progress).not_to be_empty
      expect(progress.first[:name]).to eq("chatty")
      expect(progress.first[:chunk]).to include("chunk 0")
    end

    it "throttles back-to-back chunks so a chatty tool doesn't flood the store" do
      progress = []
      bus.on(Rubino::Interaction::Events::TOOL_PROGRESS) { |p| progress << p }
      bus_executor.execute(name: "chatty", arguments: {}, call_id: "p2")
      # 5 chunks fired in a tight loop (well under TOOL_PROGRESS_INTERVAL) →
      # only the first crosses the throttle.
      expect(progress.length).to eq(1)
    end
  end

  describe "approval question formatting" do
    # #109: a no-args tool call (e.g. a bare no-arg tool) must not render a
    # dangling "wants:" header followed by nothing — reading as truncated.
    it "omits the dangling 'wants:' header entirely when there are no arguments (#109)" do
      expect(executor.send(:approval_question, tool, {})).to eq("#{tool.name} wants to run")
      expect(executor.send(:approval_question, tool, nil)).to eq("#{tool.name} wants to run")
    end

    # P7 + #558: the common one-short-arg case inlines onto the ONE consistent
    # "wants to run:" header (not the old dangling "wants:").
    it "inlines a single short argument onto the 'wants to run:' header (P7/#558)" do
      question = executor.send(:approval_question, tool, { "command" => "touch hello.txt" })
      expect(question).to eq("#{tool.name} wants to run: touch hello.txt")
    end

    # #558: every header variant uses the SAME verb phrasing ("wants to run"),
    # never the inconsistent dangling "wants:" colon.
    it "uses the single consistent 'wants to run' header across every shape (#558)" do
      no_args   = executor.send(:approval_question, tool, {})
      one_arg   = executor.send(:approval_question, tool, { "command" => "ls" })
      multi_arg = executor.send(:approval_question, tool, { "a" => "1", "b" => "2" })

      [no_args, one_arg, multi_arg].each do |q|
        expect(q).to start_with("#{tool.name} wants to run")
        # No dangling "wants:" (the colon must only follow the full verb phrase).
        expect(q).not_to match(/\bwants:/)
      end
    end

    it "lays each argument on its own line" do
      question = executor.send(:approval_question, tool,
                               { "file_path" => "a.rb", "mode" => "w" })
      expect(question).to include("file_path: a.rb")
      expect(question).to include("mode: w")
      expect(question.lines.size).to be >= 3
    end

    it "tags the count of dropped lines when a value is multi-line" do
      cmd = (1..10).map { |i| "echo #{i}" }.join("\n")
      question = executor.send(:approval_question, tool, { "command" => cmd })
      expect(question).to include("echo 1")
      expect(question).to include("echo 5")
      expect(question).to include("[… 5 more line(s)]")
      expect(question).not_to include("echo 6")
    end

    it "shows the full single-line value with no ellipsis (full-fidelity approval)" do
      long = "a" * 300
      question = executor.send(:approval_question, tool, { "blob" => long })
      # Full fidelity — the entire value survives wrapping (every character is
      # still somewhere in the question, even if split across continuation lines).
      stripped = question.delete(" \n")
      expect(stripped).to include(long)
      expect(question).not_to include("…")
      expect(question.length).to be > 300
    end

    # Security: secrets must be masked even in approval prompts.
    it "masks secrets in the approval question" do
      question = executor.send(:approval_question, tool, { "token" => "sk-secret-12345" })
      expect(question).not_to include("sk-secret-12345")
    end

    # Security: terminal escapes in arg values (CWE-150) must be defanged in the
    # approval prompt — no raw escape sequences reach the terminal scrollback.
    it "defangs terminal escapes in argument values (CWE-150)" do
      question = executor.send(:approval_question, tool,
                               { "command" => "safe\e]0;evil\acommand" })
      expect(question).not_to include("\e]0;evil\a")
      expect(question).not_to include("\e]0;")
      expect(question).to include("safe")
      expect(question).to include("command")
    end

    # Anti-regression: the multi-arg layout must disclose EVERY argument.
    # A shell call with disable_sandbox:true must still show disable_sandbox.
    it "does not hide any argument — shows disable_sandbox in multi-arg shell call" do
      question = executor.send(:approval_question, tool,
                               { "command" => "ls", "disable_sandbox" => true })
      expect(question).to include("command:")
      expect(question).to include("disable_sandbox:")
      expect(question).to include("true")
    end

    # The summary-DSL label drives the single-arg inline line: a read tool
    # with a workspace-relative summary shows the relative path, not the
    # absolute file_path.
    it "uses the summary-DSL label for the single-arg inline line (workspace-relative)" do
      tool_with_summary = Class.new(Rubino::Tools::Base) do
        def name = "read"
        def description = "reads files"
        def input_schema = { type: "object" }
        def risk_level = :low
        def call(_args) = "ok"
        summary :file_path, relative_to: :workspace
      end.new

      allow(Rubino::Workspace).to receive(:primary_root).and_return("/home/user/project")

      question = executor.send(:approval_question, tool_with_summary,
                               { "file_path" => "/home/user/project/lib/foo.rb" })
      expect(question).to eq("read wants to run: lib/foo.rb")
    end

    # Note 2 — pin workspace-relative path in the approval card for the real
    # ReadTool whose summary :file_path is marked relative_to: :workspace.
    it "shows workspace-relative path for a read inside the workspace root" do
      read_tool = Rubino::Tools::ReadTool.new
      allow(Rubino::Workspace).to receive(:primary_root).and_return("/home/user/project")

      question = executor.send(:approval_question, read_tool,
                               { "file_path" => "/home/user/project/lib/foo.rb" })
      expect(question).to eq("read wants to run: lib/foo.rb")
    end

    it "shows absolute path for a read outside the workspace root" do
      read_tool = Rubino::Tools::ReadTool.new
      allow(Rubino::Workspace).to receive(:primary_root).and_return("/home/user/project")

      question = executor.send(:approval_question, read_tool,
                               { "file_path" => "/other/dir/file.txt" })
      expect(question).to eq("read wants to run: /other/dir/file.txt")
    end

    # #582 — an MCP tool's approval card must mark it as external code: the
    # header reads `<bare> (mcp:<server>)` and an extra line names the server.
    # A built-in (the underscore-named `fake_tool` above) is unchanged.
    describe "MCP external-code marker (#582)" do
      let(:mcp_tool) do
        Rubino::MCP::MCPToolWrapper.new(
          double("mcp_tool", name: "echo", description: "echoes"), server_name: "chaos"
        )
      end

      it "uses the `<bare> (mcp:<server>)` label in the header" do
        question = executor.send(:approval_question, mcp_tool, { "text" => "BANANA" })
        expect(question).to start_with("echo (mcp:chaos) wants to run: BANANA")
      end

      it "appends the external-code disclosure line naming the server" do
        question = executor.send(:approval_question, mcp_tool, { "text" => "BANANA" })
        expect(question).to include("runs external code on MCP server 'chaos'")
      end

      it "adds the disclosure even for a no-arg MCP call" do
        question = executor.send(:approval_question, mcp_tool, {})
        expect(question).to eq("echo (mcp:chaos) wants to run\n   runs external code on MCP server 'chaos'")
      end

      it "does NOT add the external-code line for a built-in (underscore name)" do
        question = executor.send(:approval_question, tool, { "command" => "ls" })
        expect(question).to eq("fake_tool wants to run: ls")
        expect(question).not_to include("runs external code")
      end
    end

    # `edit` with an `edits` array; the generic renderer would dump an
    # unreadable escaped Ruby hash. It must preview as clean per-edit blocks.
    describe "edits-array preview" do
      let(:multi) do
        Class.new(Rubino::Tools::Base) do
          def name = "edit"
          def description = "edit"
          def input_schema = { type: "object" }
          def risk_level = :medium
          def call(_args) = "ok"

          class ToolPresentation < Rubino::Tools::ToolPresentationCLI
            APPROVAL_PREVIEW_LINES = 16

            def preview_arguments(label, arguments)
              edits = arguments["edits"] || arguments[:edits]
              return nil unless edits.is_a?(Array) && !edits.empty?

              path = arguments["file_path"] || arguments[:file_path]
              header = "#{label} wants to run: #{path} (#{edits.size} edit#{"s" if edits.size != 1})"
              body = []
              edits.each_with_index do |edit, idx|
                old_s = edit["old_string"] || edit[:old_string]
                new_s = edit["new_string"] || edit[:new_string]
                body << "" unless idx.zero?
                body.concat(old_s.to_s.lines.map { |l| "  - #{l.chomp}" })
                body.concat(new_s.to_s.lines.map { |l| "  + #{l.chomp}" })
              end
              Rubino::Util::Preview.truncate_lines!(body, APPROVAL_PREVIEW_LINES)
              ([header] + body).join("\n")
            end
          end
          presentation ToolPresentation
        end.new
      end

      it "renders per-edit - old / + new blocks instead of a raw hash" do
        question = executor.send(:approval_question, multi,
                                 { "file_path" => "stats.py",
                                   "edits" => [
                                     { "old_string" => "def median(nums):\n  s = sorted(nums)",
                                       "new_string" => "def median(nums):\n  s = sorted(nums)\n  n = len(s)" }
                                   ] })
        expect(question).to include("edit wants to run: stats.py (1 edit)")
        expect(question).to include("  - def median(nums):")
        expect(question).to include("  + def median(nums):")
        expect(question).to include("+   n = len(s)")
        # No raw Ruby hash inspect leaking literal escapes.
        expect(question).not_to include("=>")
        expect(question).not_to include('\n')
      end
    end
  end

  describe "UTF-8 safe truncation (#19)" do
    before { allow(policy).to receive(:decide).and_return(:allow) }

    it "does not produce invalid bytes when truncating mid-character" do
      # 4-byte emoji repeated past the byte cap → would split mid-char with naked byteslice
      allow(config).to receive(:dig).and_call_original
      allow(config).to receive(:dig).with("tool_output", "max_bytes").and_return(10)
      allow(config).to receive(:dig).with("tool_output", "max_lines").and_return(1_000)
      tool.output = "🚀" * 20 # 4 bytes × 20 = 80 bytes

      result = executor.execute(name: "fake_tool", arguments: {}, call_id: "c5")
      expect(result.output.valid_encoding?).to be true
      expect(result.output).to include("truncated at 10 bytes")
    end
  end

  # The unified content-routed compression seam. The executor runs every tool
  # output through Compression::ContentRouter around the truncate call: a hit
  # spills the FULL original to tool-results/<call_id>.txt and appends a read
  # pointer; a passthrough (diff/grep/short/opt-out) stays byte-identical.
  describe "compression seam (ContentRouter)" do
    before do
      allow(policy).to receive(:decide).and_return(:allow)
      allow(ui).to receive(:tool_body)
    end

    def enable_compression!
      config.set("tool_output_compression", "enabled", true)
      config.set("tool_output_compression", "logs",
                 "enabled" => true, "min_lines" => 10, "max_total_lines" => 100,
                 "max_errors" => 10, "max_warnings" => 5, "max_stack_traces" => 3,
                 "context_lines" => 4)
    end

    # A tool that returns a Hash with a log payload + a plain stream_kind hint,
    # like ShellTool does.
    let(:log_tool) do
      noisy = "#{(1..60).map { |i| "INFO line #{i}" }.join("\n")}\nERROR boom happened\nDone."
      Class.new(Rubino::Tools::Base) do
        define_method(:name) { "shell" }
        def description = "fake shell"
        def input_schema = { type: "object" }
        def risk_level = :low
        define_method(:call) do |_args|
          { output: noisy, body: "preview", body_kind: :plain,
            compress_hint: { stream_kind: :plain } }
        end
      end.new
    end

    it "compresses a log output, spills the original, and appends a PASSIVE recovery pointer" do
      enable_compression!
      allow(registry).to receive(:find).and_return(log_tool)
      result = executor.execute(name: "shell", arguments: {}, call_id: "log1")

      expect(result.output).to include("ERROR boom happened")
      expect(result.output.scan("INFO line").length).to be < 60
      expect(result.output).to include("hidden by output compression")
      expect(result.output).to include("failures + summary kept")
      expect(result.output).to include("normally sufficient")
      # Recovery is via an ID behind the retrieve_output tool — the passive
      # phrasing, keyed on the call_id, not an imperative.
      expect(result.output).to include("retrieve_output id=log1")
      expect(result.output).to include("only if a hidden line is specifically needed")
      # NO cat-able filesystem path leaks into the model-facing pointer (the
      # whole point: a small model can't sed/grep/cat a spill path to re-inflate).
      spill = File.join(spill_home, "tool-results", "log1.txt")
      expect(result.output).not_to include(spill)
      expect(result.output).not_to include(spill_home)
      expect(result.output).not_to include("tool-results")
      expect(result.output).not_to include("read /")
      expect(result.output).not_to include("full output at /")
      # the FULL original is still spilled on disk, recoverable by id
      expect(File.read(spill)).to include("INFO line 30")
    end

    it "honors compress:false (per-call opt-out) — byte-identical passthrough" do
      enable_compression!
      allow(registry).to receive(:find).and_return(log_tool)
      result = executor.execute(name: "shell", arguments: { "compress" => false }, call_id: "log2")
      expect(result.output).to include("INFO line 30")
      expect(result.output).not_to include("hidden by output compression")
    end

    def diff_tool_for(diff)
      Class.new(Rubino::Tools::Base) do
        define_method(:name) { "shell" }
        def description = "fake"
        def input_schema = { type: "object" }
        def risk_level = :low
        define_method(:call) { |_a| { output: diff, compress_hint: { stream_kind: :diff } } }
      end.new
    end

    it "passes a SMALL/tight diff through byte-identical (saving guard)" do
      enable_compression!
      diff = "diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\n context\n"
      allow(registry).to receive(:find).and_return(diff_tool_for(diff))
      result = executor.execute(name: "shell", arguments: {}, call_id: "d1")
      expect(result.output).to eq(diff)
      expect(result.output).not_to include("hidden by output compression")
    end

    it "COMPRESSES a large wide-context diff, keeping +/- lines + headers" do
      enable_compression!
      ctx = (1..40).map { |i| " ctx#{i}" }.join("\n")
      diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,42 +1,42 @@\n-removed\n+added\n#{ctx}\n"
      allow(registry).to receive(:find).and_return(diff_tool_for(diff))
      result = executor.execute(name: "shell", arguments: {}, call_id: "d2")
      expect(result.output).to include("-removed")
      expect(result.output).to include("+added")
      expect(result.output).to include("diff --git a/x b/x")
      expect(result.output).to match(/… \d+ unchanged lines/)
      # the diff-aware recovery pointer wording
      expect(result.output).to include("all +/- changes + headers kept")
    end

    it "leaves output untouched when compression is disabled (default)" do
      allow(registry).to receive(:find).and_return(log_tool)
      result = executor.execute(name: "shell", arguments: {}, call_id: "log3")
      expect(result.output).to include("INFO line 30")
      expect(result.output).not_to include("hidden by output compression")
    end
  end

  # ── live_card opt-in: inline tool adapter registration ──────────
  # When a tool class declares `live_card`, the executor creates an
  # InlineToolAdapter, registers it in BackgroundTasks so it appears in
  # the dropdown, tees streamed output into its buffer, and
  # finishes/unregisters it in the ensure block (also on error).
  describe "live_card inline tool adapter" do
    let(:live_card_tool_class) do
      Class.new(Rubino::Tools::Base) do
        def name = "build_tool"
        def description = "builds things"
        def input_schema = { type: "object" }
        attr_writer :output, :stream_callback

        def call(_args)
          # Simulate streaming output
          @stream_callback&.call("building...\n")
          @stream_callback&.call("done\n")
          @output.nil? ? "ok" : @output
        end

        def stream_chunk=(cb)
          @stream_callback = cb
        end

        def stream_chunk
          @stream_callback
        end
      end
    end

    let(:plain_tool_class) do
      Class.new(Rubino::Tools::Base) do
        def name = "quiet_tool"
        def description = "quiet"
        def input_schema = { type: "object" }
        def call(_args) = "done"
      end
    end

    let(:live_tool) { live_card_tool_class.new }
    let(:plain_tool) { plain_tool_class.new }
    # UI must respond to tool_chunk for the stream_chunk lambda to be installed
    let(:ui) { double("UI", confirm: true, interactive?: true, tool_chunk: nil, tool_body: nil) }

    before do
      # The test tools need the approval policy to allow them.
      allow(policy).to receive(:decide).and_return(:allow)
    end

    after do
      # Clean up any leftover inline adapters
      registry_instance = Rubino::Tools::BackgroundTasks.instance
      registry_instance.running.select { |e| e.id.start_with?("il_") }.each do |entry|
        registry_instance.unregister_inline(entry.id)
      end
    end

    it "registers an inline adapter when the tool class declares live_card" do
      live_card_tool_class.live_card(->(_t) { "🔨 building" })
      allow(registry).to receive(:find).with("build_tool").and_return(live_tool)

      registry_instance = Rubino::Tools::BackgroundTasks.instance
      before_count = registry_instance.running.select { |e| e.id.start_with?("il_") }.size

      executor.execute(name: "build_tool", arguments: { target: "app" }, call_id: "c1")

      # After the call, the adapter should have been cleaned up (finish! + unregister).
      after_count = registry_instance.running.select { |e| e.id.start_with?("il_") }.size
      expect(after_count).to eq(before_count)
    end

    it "registers an inline adapter with the header from the lambda" do
      live_card_tool_class.live_card(->(_t) { "🔨 building" })
      allow(registry).to receive(:find).with("build_tool").and_return(live_tool)

      registry_instance = Rubino::Tools::BackgroundTasks.instance
      executor.execute(name: "build_tool", arguments: { target: "app" }, call_id: "c1")

      # The adapter was registered during the call but is cleaned up by ensure.
      # After the call, no inline adapters should remain.
      live_inlines = registry_instance.running.select { |e| e.id.start_with?("il_") }
      expect(live_inlines).to be_empty
    end

    it "does NOT register anything when the tool class has no live_card (opt-in default)" do
      allow(registry).to receive(:find).with("quiet_tool").and_return(plain_tool)

      registry_instance = Rubino::Tools::BackgroundTasks.instance
      before = registry_instance.running.size
      executor.execute(name: "quiet_tool", arguments: {}, call_id: "c2")
      expect(registry_instance.running.size).to eq(before)
    end

    it "tees streamed output into the adapter buffer" do
      live_card_tool_class.live_card(->(_t) { "building" })
      allow(registry).to receive(:find).with("build_tool").and_return(live_tool)

      registry_instance = Rubino::Tools::BackgroundTasks.instance
      expect(registry_instance).to receive(:register_inline).and_call_original

      executor.execute(name: "build_tool", arguments: {}, call_id: "c3")

      # Bug A retain-for-replay: finished adapter stays retrievable, output
      # buffer is preserved — no unregister on finish.
      adapter = registry_instance.list.find { |e| e.tool_name == "build_tool" }
      expect(adapter).not_to be_nil
      expect(adapter.output_all).to include("building")
      expect(adapter.live?).to be(false)
      expect(registry_instance.running.map(&:id)).not_to include(adapter.id)
    end

    it "finishes the adapter even when the tool raises (retained, not unregistered)" do
      failing_tool_class = Class.new(Rubino::Tools::Base) do
        def name = "crash_tool"
        def description = "crashes"
        def input_schema = { type: "object" }
        attr_writer :stream_callback

        def call(_args)
          @stream_callback&.call("starting...\n")
          raise "boom"
        end

        def stream_chunk=(cb)
          @stream_callback = cb
        end
      end
      failing_tool_class.live_card(->(_args) { "crash tool" })
      failing_tool = failing_tool_class.new
      allow(registry).to receive(:find).with("crash_tool").and_return(failing_tool)

      registry_instance = Rubino::Tools::BackgroundTasks.instance
      executor.execute(name: "crash_tool", arguments: {}, call_id: "c4")

      # After the error, the adapter is NOT running (live?=false) but is
      # retained for replay (Bug A).
      live_inlines = registry_instance.running.select { |e| e.id.start_with?("il_") }
      expect(live_inlines).to be_empty

      # It's still retrievable via list/find, with the partial output.
      adapter = registry_instance.list.find { |e| e.tool_name == "crash_tool" }
      expect(adapter).not_to be_nil
      expect(adapter.output_all).to include("starting")
    end

    it "falls back to the tool name when the header lambda raises" do
      live_card_tool_class.live_card(->(_args) { raise "bad lambda" })
      allow(registry).to receive(:find).with("build_tool").and_return(live_tool)

      registry_instance = Rubino::Tools::BackgroundTasks.instance
      expect(registry_instance).to receive(:register_inline).and_call_original

      executor.execute(name: "build_tool", arguments: {}, call_id: "c5")

      # The header fallback is logged; the adapter is retained (Bug A),
      # not unregistered.
      adapter = registry_instance.list.find { |e| e.tool_name == "build_tool" }
      expect(adapter).not_to be_nil
      expect(adapter.live?).to be(false)
    end
  end

  describe "source_session_id attribution" do
    it "sets memory_source_session_id thread-local during tool execution" do
      executor = described_class.new(
        registry: registry, approval_policy: policy, ui: ui,
        config: config, session_id: "sess-42"
      )

      allow(policy).to receive(:decide).and_return(:allow)
      allow(policy).to receive(:last_deny_reason).and_return(nil)
      allow(policy).to receive(:last_ask_reason).and_return(nil)
      allow(policy).to receive(:workspace_widen_dirs).and_return([])

      captured_before = Rubino.memory_source_session_id

      tool_class = Class.new(Rubino::Tools::Base) do
        redaction_profile :none

        def name = "spy_tool"
        def description = "spy"
        def risk_level = :low

        def call(_args)
          Rubino.memory_source_session_id
        end
      end

      spy_tool = tool_class.new
      allow(registry).to receive(:find).with("spy_tool").and_return(spy_tool)

      result = executor.execute(name: "spy_tool", arguments: {}, call_id: "c_spy")

      expect(captured_before).to be_nil
      # The tool sees the session_id during its call
      expect(result.output).to eq("sess-42")
      # Thread-local is restored after execution
      expect(Rubino.memory_source_session_id).to be_nil
    end
  end

  # Hot retry on escalation denial (Codex-style): when a shell command hits
  # a write-jail EACCES, the executor re-prompts and re-runs unsandboxed
  # in the same turn — zero extra model round-trips.
  describe "escalation hot retry" do
    let(:shell_tool) do
      Class.new(Rubino::Tools::ShellTool) do
        def name = "shell"
        def rerun_escalated(_command, _cwd, _timeout)
          { output: "escalated-ok", metrics: "exit 0 · 100ms",
            exit_code: 0, timed_out: false, cancelled: false,
            error_code: nil }
        end
      end.new
    end

    before do
      allow(registry).to receive(:find).with("shell").and_return(shell_tool)
      allow(Rubino::Security::Sandbox).to receive(:enforcing?).and_return(true)
      allow(Rubino::Security::Sandbox).to receive(:escalation_allowed?).and_return(true)
      allow(policy).to receive(:decide).and_return(:allow)
    end

    it "retries unsandboxed when the first attempt hits the write-jail" do
      # First attempt returns EACCES text that write_jail_attribution matches
      denied_output = "/usr/local/bin/x: Permission denied"
      allow(shell_tool).to receive(:call).and_return(
        Rubino::Tools::Result.new(name: "shell", call_id: "c1", output: denied_output, status: :success)
      )
      allow(Rubino::Security::Sandbox).to receive(:write_jail_attribution)
        .with(denied_output, cwd: anything).and_return("(blocked by the workspace write-jail)")

      result = executor.execute(
        name: "shell",
        arguments: { "command" => "pip install x", "cwd" => "/tmp", "timeout" => 30 },
        call_id: "c1"
      )

      expect(result.output).to eq("escalated-ok")
    end

    it "does NOT retry when the jail is not enforcing" do
      allow(Rubino::Security::Sandbox).to receive(:enforcing?).and_return(false)

      denied_output = "/usr/local/bin/x: Permission denied"
      allow(shell_tool).to receive(:call).and_return(
        Rubino::Tools::Result.new(name: "shell", call_id: "c2", output: denied_output, status: :success)
      )

      result = executor.execute(
        name: "shell",
        arguments: { "command" => "pip install x" },
        call_id: "c2"
      )

      expect(result.output).to eq(denied_output)
    end

    it "does NOT retry when the text has no jail denial pattern" do
      normal_output = "Successfully installed x-1.0"
      allow(shell_tool).to receive(:call).and_return(
        Rubino::Tools::Result.new(name: "shell", call_id: "c3", output: normal_output, status: :success)
      )
      allow(Rubino::Security::Sandbox).to receive(:write_jail_attribution)
        .with(normal_output, cwd: anything).and_return(nil)

      result = executor.execute(
        name: "shell",
        arguments: { "command" => "pip install x" },
        call_id: "c3"
      )

      expect(result.output).to eq(normal_output)
    end
    it "passes the real command (not disclosure text) to the approval UI" do
      denied_output = "/usr/local/bin/x: Permission denied"
      allow(shell_tool).to receive(:call).and_return(
        Rubino::Tools::Result.new(name: "shell", call_id: "c5", output: denied_output, status: :success)
      )
      allow(Rubino::Security::Sandbox).to receive(:write_jail_attribution)
        .with(denied_output, cwd: anything).and_return("(blocked by the workspace write-jail)")

      disclosure = Rubino::Security::Sandbox.escalation_disclosure
      expect(ui).to receive(:confirm).with(
        "The sandbox blocked this write. Retry outside the sandbox?",
        scope: "escalation:c5",
        tool: "shell",
        command: "pip install x",
        description: disclosure
      ).and_return(true)

      executor.execute(
        name: "shell",
        arguments: { "command" => "pip install x", "cwd" => "/tmp", "timeout" => 30 },
        call_id: "c5"
      )
    end

    it "does NOT retry when the UI is not interactive (one-shot/CI fallback)" do
      allow(ui).to receive(:interactive?).and_return(false)

      denied_output = "/opt/x: Permission denied"
      allow(shell_tool).to receive(:call).and_return(
        Rubino::Tools::Result.new(name: "shell", call_id: "c4", output: denied_output, status: :success)
      )
      allow(Rubino::Security::Sandbox).to receive(:write_jail_attribution)
        .with(denied_output, cwd: anything).and_return("(blocked)")

      result = executor.execute(
        name: "shell",
        arguments: { "command" => "touch /opt/x" },
        call_id: "c4"
      )

      # Non-interactive: model sees the denial, no retry
      expect(result.output).to eq(denied_output)
    end
  end
end
