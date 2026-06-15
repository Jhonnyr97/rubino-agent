# frozen_string_literal: true

require "stringio"

# The one-shot TEXT trace adapter: a Null adapter (keeping every fail-closed /
# block-latch behaviour) that adds ONE concise `· name hint` line per tool
# completion, routed to an injectable IO (real $stderr in production).
RSpec.describe Rubino::UI::HeadlessTrace do
  subject(:ui) { described_class.new(io: io) }

  let(:io) { StringIO.new }

  it "is a Null adapter, so it inherits the fail-closed approval floor" do
    expect(ui).to be_a(Rubino::UI::Null)
    expect(ui.interactive?).to be(false)
    expect(ui.confirm("write?", scope: :session)).to be(false)
  end

  it "emits ONE `· name hint` line per tool completion, on the trace IO" do
    ui.tool_started("edit", arguments: { file_path: "foo.rb" })
    ui.tool_finished("edit")
    ui.tool_started("bash", arguments: { command: "npm test" })
    ui.tool_finished("bash")

    expect(io.string).to eq("· edit foo.rb\n· bash npm test\n")
  end

  it "emits on COMPLETION, not on start (a tool that never returns leaves no line)" do
    ui.tool_started("read", arguments: { file_path: "a.rb" })
    expect(io.string).to eq("")
    ui.tool_finished("read")
    expect(io.string).to eq("· read a.rb\n")
  end

  it "falls back to the bare tool name when there is no identifying argument" do
    ui.tool_started("todo", arguments: {})
    ui.tool_finished("todo")
    expect(io.string).to eq("· todo\n")
  end

  it "masks secrets and strips terminal escapes in the hint" do
    ui.tool_started("bash", arguments: { command: "echo \e]0;pwn\a hi" })
    ui.tool_finished("bash")
    expect(io.string).not_to include("\e]0;")
  end

  it "still latches an approval block (Null behaviour preserved)" do
    ui.tool_blocked("write to /etc blocked")
    expect(ui.approval_blocked?).to be(true)
    expect(ui.blocked_messages).to include("write to /etc blocked")
  end

  describe "verbose" do
    it "widens the hint cap so a longer arg is shown more fully" do
      long = "a/very/long/path/that/exceeds/the/default/sixty/character/hint/cap/here.rb"
      plain   = described_class.new(io: StringIO.new)
      verbose = described_class.new(io: StringIO.new, verbose: true)

      plain.tool_started("read", arguments: { file_path: long })
      plain.tool_finished("read")
      verbose.tool_started("read", arguments: { file_path: long })
      verbose.tool_finished("read")

      plain_line   = plain.instance_variable_get(:@trace_io).string
      verbose_line = verbose.instance_variable_get(:@trace_io).string
      expect(plain_line).to include("...")
      expect(verbose_line).to include(long)
    end
  end
end
