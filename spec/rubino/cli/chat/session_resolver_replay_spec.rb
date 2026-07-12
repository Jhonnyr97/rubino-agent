# frozen_string_literal: true

require "stringio"

# Resume-replay render parity (polish-p1 items 3 + 4):
#   * a denied/failed tool row must replay with the red ✗ ("failed …"), not a
#     blanket green ✓ (the replay path used to wrap every stored tool row as
#     Result.success regardless of its persisted outcome).
#   * adjacent assistant text segments must be separated by a blank line on
#     replay, matching the live path (#assistant_text → #answer_gap).
RSpec.describe Rubino::CLI::Chat::SessionResolver, "#print_session_history" do
  subject(:resolver) { described_class.new({}) }

  let(:ui) { Rubino::UI::CLI.new }
  let(:msg_class) do
    Struct.new(:role, :content, :tool_name, :tool_call_id, :metadata, :created_at,
               keyword_init: true)
  end

  def msg(**attrs)
    msg_class.new(**attrs)
  end

  def stub_session(messages)
    store = instance_double(Rubino::Session::Store)
    allow(Rubino::Session::Store).to receive(:new).and_return(store)
    allow(store).to receive(:for_session).with("sess-1").and_return(messages)
  end

  def replay(messages)
    stub_session(messages)
    old = $stdout
    $stdout = StringIO.new
    resolver.send(:print_session_history, ui, "sess-1")
    $stdout.string
  ensure
    $stdout = old
  end

  def plain(out)
    out.gsub(/\e\[[0-9;]*m/, "")
  end

  describe "denied / failed tool glyph (item 3)" do
    it "replays a DENIED tool with the red ✗ failed row, not a green ✓" do
      out = replay([
                     msg(role: "tool", content: "Tool execution denied by user.",
                         tool_name: "write", tool_call_id: "t1",
                         metadata: { arguments: { file_path: "hello.txt" }, status: "denied" },
                         created_at: Time.now)
                   ])
      txt = plain(out)
      expect(txt).to include("✗ failed · write")
      expect(txt).not_to include("✓ Tool execution denied")
    end

    it "replays a FAILED tool (error status) with the ✗ row" do
      out = replay([
                     msg(role: "tool", content: "Error: boom", tool_name: "shell",
                         tool_call_id: "t2",
                         metadata: { status: "error", error_code: "exit_1" },
                         created_at: Time.now)
                   ])
      expect(plain(out)).to include("✗ failed · shell")
    end

    it "replays a SUCCESSFUL tool with the quiet ✓ row" do
      out = replay([
                     msg(role: "tool", content: "ok", tool_name: "read",
                         tool_call_id: "t3", metadata: { status: "success" },
                         created_at: Time.now)
                   ])
      txt = plain(out)
      expect(txt).to include("└ ✓")
      expect(txt).not_to include("✗ failed")
    end

    it "infers a denial from the output text for LEGACY rows (no persisted status)" do
      out = replay([
                     msg(role: "tool", content: "Tool execution denied by user.",
                         tool_name: "write", tool_call_id: "t4",
                         metadata: { arguments: { file_path: "x" } }, # no :status
                         created_at: Time.now)
                   ])
      expect(plain(out)).to include("✗ failed · write")
    end
  end

  # A resumed session must NOT repaint the subagent (`task`) delegation timeline:
  # those cards/rows are backed by the in-process BackgroundTasks registry, which
  # dies with the process, so on a fresh launch that auto-resumes the folder's
  # last session they'd describe children that no longer exist ("phantom old
  # subagent timeline"). The `task` rows are skipped in scrollback; the model
  # still receives them via PromptAssembler.
  describe "subagent (task) rows on resume" do
    it "does not repaint a delegation timeline for a persisted task row" do
      out = replay([
                     msg(role: "user", content: "delegate this",
                         metadata: {}, created_at: Time.now),
                     msg(role: "tool", content: "subagent done",
                         tool_name: "task", tool_call_id: "sa1",
                         metadata: { arguments: { description: "explore repo" },
                                     status: "success" },
                         created_at: Time.now)
                   ])
      txt = plain(out)
      # the user prompt still replays…
      expect(txt).to include("delegate this")
      # …but nothing from the task delegation surface leaks into scrollback.
      expect(txt).not_to include("delegated")
      expect(txt).not_to include("subagent done")
    end

    it "still replays a normal (non-task) tool row" do
      out = replay([
                     msg(role: "tool", content: "ok", tool_name: "read",
                         tool_call_id: "r1", metadata: { status: "success" },
                         created_at: Time.now)
                   ])
      expect(plain(out)).to include("└ ✓")
    end
  end

  describe "adjacent assistant text separation (item 4)" do
    it "separates two adjacent assistant segments with a blank line, never glued" do
      out = replay([
                     msg(role: "assistant", content: "I'll proceed with that text.",
                         metadata: {}, created_at: Time.now),
                     msg(role: "assistant", content: "Created hello.txt",
                         metadata: {}, created_at: Time.now)
                   ])
      txt = plain(out)
      # The two segments are NOT concatenated onto one line…
      expect(txt).not_to include("that text.Created hello.txt")
      # …and a blank line sits between them (the live separator, on replay).
      expect(txt).to match(/that text\.\n\s*\n\s*Created hello\.txt/)
    end
  end

  # #542: some tool-loop providers (MiniMax-M3) return a FINAL assistant message
  # whose content is the WHOLE turn's text accumulated across tool rounds — every
  # earlier "pre-tool" segment concatenated with NO separator
  # (`…which prints 2.Output is 2…`). Those earlier segments were ALSO persisted
  # as their own intermediate assistant rows (replayed above), so re-rendering the
  # final message verbatim both GLUED them and DUPLICATED them — while the live
  # turn showed each segment once, on its own line. Replay must render only the
  # genuinely-new tail of a restated final message, through #assistant_text (which
  # supplies the live blank-line separator).
  describe "restated final message (the #542 glue)" do
    it "does not glue or duplicate a final message that restates earlier segments" do
      t = Time.now
      pre = "The file contains a single line: puts 1+1, which prints 2."
      post = "Output is 2, as expected."
      out = replay([
                     msg(role: "user", content: "read calc.rb then run it",
                         metadata: {}, created_at: t),
                     # intermediate pre-tool text (its own persisted row)
                     msg(role: "assistant", content: pre,
                         metadata: { tool_calls: [{}] }, created_at: t + 1),
                     msg(role: "tool", content: "2", tool_name: "shell",
                         tool_call_id: "x", metadata: { status: "success" },
                         created_at: t + 2),
                     # FINAL message restates the pre-tool text glued to the new tail
                     msg(role: "assistant", content: "#{pre}#{post}",
                         metadata: {}, created_at: t + 3)
                   ])
      # Collapse render whitespace so a narrow-terminal hard-wrap in the markdown
      # renderer doesn't split a sentence across lines and fool the substring math.
      txt  = plain(out)
      flat = txt.gsub(/\s+/, " ")
      # The verbatim #542 glue must NOT appear…
      expect(txt).not_to include("prints 2.Output is 2")
      # …each segment is shown exactly ONCE (no duplication from the restatement)…
      expect(flat.scan("which prints 2.").size).to eq(1)
      expect(flat.scan("Output is 2, as expected.").size).to eq(1)
      # …and the new tail still renders (separated by the live answer_gap).
      expect(flat).to include(post)
    end

    it "renders the new tail as its own block when the model restates two segments" do
      t = Time.now
      a = "Reading the file now."
      b = "It prints 2."
      out = replay([
                     msg(role: "assistant", content: a,
                         metadata: { tool_calls: [{}] }, created_at: t),
                     msg(role: "tool", content: "ok", tool_name: "read",
                         tool_call_id: "r", metadata: { status: "success" },
                         created_at: t + 1),
                     # final restates "a" then adds "b", glued
                     msg(role: "assistant", content: "#{a}#{b}",
                         metadata: {}, created_at: t + 2)
                   ])
      flat = plain(out).gsub(/\s+/, " ")
      expect(plain(out)).not_to include("now.It prints")
      expect(flat.scan(a).size).to eq(1)
      expect(flat).to include(b)
    end

    it "resets the restatement window at a new user turn" do
      t = Time.now
      # Same text in two SEPARATE turns must both render — the second is not a
      # restatement of the first (the user boundary resets the accumulator).
      out = replay([
                     msg(role: "user", content: "turn one", metadata: {}, created_at: t),
                     msg(role: "assistant", content: "Done.", metadata: {}, created_at: t + 1),
                     msg(role: "user", content: "turn two", metadata: {}, created_at: t + 2),
                     msg(role: "assistant", content: "Done.", metadata: {}, created_at: t + 3)
                   ])
      expect(plain(out).scan("Done.").size).to eq(2)
    end
  end

  # #699 / F5: after `/clear` (or attach/detach), replayed tool cards whose live
  # output was multi-line (shell tables, listings) were reconstructed FLATTENED
  # onto one line joined by " — ", with a stray separator underneath. Root cause:
  # the replay path rendered only tool_started + tool_finished, omitting the BODY
  # — so the compact close row's #truncate_inline (which collapses \n to " — ")
  # was the ONLY visible rendering of the tool's output. The fix inserts
  # ui.tool_body between them, the SAME live seam the live turn uses.
  describe "tool body replay (multi-line preservation, #699)" do
    it "replays a multi-line tool output with intact line breaks, not ' — ' joined" do
      out = replay([
                     msg(role: "tool",
                         content: "┌─────────────┬─────────┐\n│ Tool        │ Status  │\n└─────────────┴─────────┘",
                         tool_name: "shell", tool_call_id: "t1",
                         metadata: { arguments: { command: "echo table" }, status: "success" },
                         created_at: Time.now)
                   ])
      txt = plain(out)
      # The full multi-line table must appear with its box-drawing glyphs and
      # line breaks preserved — NOT collapsed into a " — "-joined one-liner.
      expect(txt).to include("┌─────────────┬─────────┐")
      expect(txt).to include("│ Tool        │ Status  │")
      expect(txt).to include("└─────────────┴─────────┘")
      # The " — " joining is #truncate_inline's signature — must NOT appear in
      # the body area (only the compact close row may use it, and only for the
      # single-line metric, not the full body).
      body_area = txt.split(/└ [✓✗]/).first
      expect(body_area).not_to include(" — ")
    end

    it "still renders the compact close row ✓ with its truncated metric" do
      out = replay([
                     msg(role: "tool", content: "line one\nline two",
                         tool_name: "read", tool_call_id: "t2",
                         metadata: { status: "success" },
                         created_at: Time.now)
                   ])
      txt = plain(out)
      # The compact close row still shows (it's the ✓ line after the body)
      expect(txt).to include("└ ✓")
      # The body shows multi-line
      expect(txt).to include("line one")
      expect(txt).to include("line two")
    end

    it "does not crash or render body for an empty-content tool row" do
      out = replay([
                     msg(role: "tool", content: "",
                         tool_name: "shell", tool_call_id: "t3",
                         metadata: { status: "success" },
                         created_at: Time.now)
                   ])
      txt = plain(out)
      expect(txt).to include("└ ✓")
    end

    it "replays a denied/failed multi-line tool with its body intact and ✗ glyph" do
      out = replay([
                     msg(role: "tool",
                         content: "Error:\nbranch not found\ncheck your spelling",
                         tool_name: "shell", tool_call_id: "t4",
                         metadata: { status: "error", error_code: "exit_1" },
                         created_at: Time.now)
                   ])
      txt = plain(out)
      expect(txt).to include("✗ failed")
      expect(txt).to include("branch not found")
      expect(txt).to include("check your spelling")
    end
  end

  # The reusable public entry the agent-attach view switch replays through (it
  # clears the screen and replays the SELECTED agent's own session).
  # #print_session_history now delegates to it, so the parity specs above already
  # exercise the render loop.
  describe "#replay_session" do
    # Mirrors the file's #replay helper but drives the new public entry point.
    def replay_via_session(session_id, messages = nil)
      stub_session(messages) if messages
      old = $stdout
      $stdout = StringIO.new
      resolver.replay_session(ui, session_id)
      $stdout.string
    ensure
      $stdout = old
    end

    it "is a public no-op for a nil session id" do
      expect(replay_via_session(nil)).to eq("")
    end

    it "replays the session's messages through the live UI hooks" do
      out = replay_via_session(
        "sess-1",
        [msg(role: "user", content: "hello there", metadata: {}, created_at: Time.now)]
      )
      expect(plain(out)).to include("hello there")
    end
  end
end
