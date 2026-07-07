# frozen_string_literal: true

# Covers the hygiene trio in Commands::Executor: /compact (manual compaction
# NOW, via the same Context::Compressor + compression_started/finished events
# the automatic threshold path runs), /clear (the muscle-memory alias for
# /new), and /export (the session transcript as clean markdown).
RSpec.describe Rubino::Commands::Executor do
  subject(:exec) { described_class.new(loader: loader, ui: ui, runner: runner) }

  let(:db)     { test_database }
  let(:ui)     { Rubino::UI::Null.new }
  let(:loader) { Rubino::Commands::Loader.new(config: test_configuration) }
  let(:store)  { Rubino::Session::Store.new(db: db.db) }
  let(:repo)   { Rubino::Session::Repository.new(db: db.db) }

  let(:session) { repo.create(source: "cli", model: "gpt-4.1", provider: "openai") }
  let(:runner) do
    instance_double(Rubino::Agent::Runner, session: session)
  end

  before do
    allow(Rubino).to receive(:database).and_return(db)
  end

  # /compact now clears the SAME 64K compaction floor the auto path enforces, so
  # the offline mechanics specs below must force the gate (they run on tiny
  # transcripts). Stubs the class to build a REAL budget — so before/after token
  # estimates stay truthful — then forces needs_compaction? true on it. Avoids
  # allow_any_instance_of (banned by RSpec/AnyInstance in this file).
  def force_compaction_gate
    allow(Rubino::Context::TokenBudget).to receive(:new).and_wrap_original do |orig, **kw|
      orig.call(**kw).tap { |b| allow(b).to receive(:needs_compaction?).and_return(true) }
    end
  end

  describe "/clear" do
    it "returns the same {new_session:} signal as /new" do
      expect(exec.try_execute("/clear")).to eq(new_session: true)
      expect(exec.try_execute("/new")).to eq(new_session: true)
    end
  end

  describe "/compact" do
    it "errors (handled) when no live session exists" do
      bare = described_class.new(loader: loader, ui: ui)
      expect(bare.try_execute("/compact")).to eq(:handled)
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("nothing to compact")
    end

    it "reports nothing-to-compact for a session below the protected size" do
      3.times { |i| store.create(session_id: session[:id], role: "user", content: "msg #{i}") }

      expect(exec.try_execute("/compact")).to eq(:handled)
      out = ui.messages.map { |m| m[:message].to_s }.join("\n")
      expect(out).to include("Nothing to compact yet")
    end

    context "with a session past the protected head/tail size" do
      before do
        # Force the token-budget gate so this offline transcript actually
        # compacts: /compact now no-ops below the 64K floor (like the auto path),
        # which the dedicated below-threshold spec covers. Here we test the
        # post-gate report mechanics.
        force_compaction_gate
        # minimum = protect_first_n(3) + protect_last_n(20) + 5
        30.times do |i|
          role = i.even? ? "user" : "assistant"
          store.create(session_id: session[:id], role: role, content: "turn #{i} #{"x" * 200}")
        end
        # Keep the spec offline + deterministic: the summary call is stubbed out.
        allow(Rubino::Context::SummaryBuilder).to receive(:new)
          .and_return(instance_double(Rubino::Context::SummaryBuilder, build: "the summary"))
      end

      it "compacts through the compression UI events and reports tokens before → after" do
        result = exec.try_execute("/compact")

        expect(result).to be_a(Hash)
        child_id = result[:compact_into]
        expect(child_id).not_to be_nil

        levels = ui.messages.map { |m| m[:level] }
        expect(levels).to include(:compression_started, :compression_finished)

        report = ui.messages.find { |m| m[:message].to_s.start_with?("Context: ~") }
        expect(report[:message]).to match(/Context: ~\d+ → ~\d+ tokens/)

        # The child really is smaller, and the source is marked compacted.
        expect(store.count(child_id)).to be < store.count(session[:id])
        expect(repo.find(session[:id])[:status]).to eq("compacted")
      end
    end

    it "degrades to a handled error when compaction raises" do
      5.times { |i| store.create(session_id: session[:id], role: "user", content: "m#{i}") }
      allow(Rubino::Context::Compressor).to receive(:new).and_raise(Rubino::CompactionError, "boom")

      expect(exec.try_execute("/compact")).to eq(:handled)
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("compaction failed: boom")
    end

    # Symptom 1 + 3 at the command boundary: a small session (enough messages,
    # but well under the token threshold) must NO-OP — no compression UI, no
    # paid summary, and crucially NO {compact_into:} signal so the REPL does NOT
    # silently fork the session id out from under the user.
    it "no-ops a below-threshold session: clear message, no UI events, no session fork" do
      # 40 short messages clears the minimum-messages floor but is far below the
      # default 64K token threshold.
      40.times { |i| store.create(session_id: session[:id], role: "user", content: "short #{i}") }

      result = exec.try_execute("/compact")

      expect(result).to eq(:handled) # NOT a {compact_into:} fork
      levels = ui.messages.map { |m| m[:level] }
      expect(levels).not_to include(:compression_started, :compression_finished)
      out = ui.messages.map { |m| m[:message].to_s }.join("\n")
      expect(out).to include("under the compaction threshold")
      expect(repo.find(session[:id])[:status]).not_to eq("compacted")
    end

    # Symptom 2: the reported delta must be TRUTHFUL. The old path reported the
    # compressor's "removed middle" estimate, which ignored the inserted summary
    # and so printed "saved N" even when context grew. Here we force a large
    # summary on a just-over-threshold session and assert the report reflects the
    # real before→after — never a false "saved" when the result is not smaller.
    it "reports the real before→after delta, never a false saving when context grows" do
      force_compaction_gate
      30.times do |i|
        role = i.even? ? "user" : "assistant"
        store.create(session_id: session[:id], role: role, content: "turn #{i} #{"x" * 200}")
      end
      # A summary far LARGER than the middle it replaces → the child is bigger.
      allow(Rubino::Context::SummaryBuilder).to receive(:new)
        .and_return(instance_double(Rubino::Context::SummaryBuilder, build: "S" * 40_000))

      exec.try_execute("/compact")

      report = ui.messages.find { |m| m[:message].to_s.start_with?("Context: ~") }[:message].to_s
      # The report states the honest direction (grew), and never lies "saved".
      expect(report).to match(/grew ~\d+ tok/)
      expect(report).not_to include("saved")
    end
  end

  describe "/export" do
    around do |example|
      Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
    end

    before do
      store.create(session_id: session[:id], role: "user", content: "hello there")
      store.create(session_id: session[:id], role: "assistant", content: "hi! let me look",
                   metadata: { tool_calls: [{ id: "c1", name: "shell", arguments: { command: "ls" } }] })
      store.create(session_id: session[:id], role: "tool", content: "a.txt\nb.txt", tool_name: "shell")
    end

    it "writes ./rubino-session-<id8>.md by default and prints the path" do
      expect(exec.try_execute("/export")).to eq(:handled)

      expected = File.expand_path("rubino-session-#{session[:id][0, 8]}.md")
      expect(File).to exist(expected)
      msg = ui.messages.find { |m| m[:level] == :success }
      expect(msg[:message]).to include(expected)
    end

    it "honors an explicit path argument" do
      exec.try_execute("/export transcript.md")
      expect(File).to exist(File.expand_path("transcript.md"))
    end

    it "exports clean markdown: turns verbatim, tool calls as one-liners" do
      exec.try_execute("/export out.md")
      md = File.read("out.md")

      expect(md).to include("## User", "hello there")
      expect(md).to include("## Assistant", "hi! let me look")
      expect(md).to include("- tool call: `shell`")
      expect(md).to include("- tool result: `shell`")
    end

    it "errors when no live session exists" do
      bare = described_class.new(loader: loader, ui: ui)
      bare.try_execute("/export")
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("no live session")
    end
  end

  it "registers the trio as discoverable built-ins" do
    expect(Rubino::Commands::BuiltIns::NAMES).to include("/compact", "/clear", "/export")
  end
end
