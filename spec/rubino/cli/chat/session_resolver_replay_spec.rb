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
