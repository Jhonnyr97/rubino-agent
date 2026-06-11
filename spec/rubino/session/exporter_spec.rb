# frozen_string_literal: true

# The /export serializer: one session's transcript as clean markdown —
# user/assistant turns verbatim, tool calls and results as one-liners,
# system rows (prompt scaffolding, compaction summaries) omitted.
RSpec.describe Rubino::Session::Exporter do
  subject(:exporter) { described_class.new(session, store: store) }

  let(:db)      { test_database }
  let(:store)   { Rubino::Session::Store.new(db: db.db) }
  let(:repo)    { Rubino::Session::Repository.new(db: db.db) }
  let(:session) { repo.create(source: "cli", model: "gpt-4.1", title: "demo") }

  def markdown
    exporter.markdown
  end

  it "leads with a header carrying the short id and metadata" do
    expect(markdown.lines.first).to eq("# rubino session #{session[:id][0, 8]}\n")
    expect(markdown).to include("- session: #{session[:id]}")
    expect(markdown).to include("- title: demo")
    expect(markdown).to include("- model: gpt-4.1")
  end

  it "renders user and assistant turns verbatim, in order" do
    store.create(session_id: session[:id], role: "user", content: "first question")
    store.create(session_id: session[:id], role: "assistant", content: "first answer")

    expect(markdown).to match(/## User\n\nfirst question\n.*## Assistant\n\nfirst answer/m)
  end

  # The shape the LIVE streaming path persists (#216): the assistant tool-use
  # turn carries NO tool_calls metadata; the call arguments ride the separate
  # `tool`-role result row, which is where the exporter reconstructs the call
  # one-liner from.
  it "renders tool calls and results as one-liners" do
    store.create(session_id: session[:id], role: "assistant", content: "")
    store.create(session_id: session[:id], role: "tool", content: "a.txt", tool_name: "shell",
                 metadata: { arguments: { command: "ls" } })

    expect(markdown).to include('- tool call: `shell` `{"command":"ls"}`')
    expect(markdown).to include("- tool result: `shell` (5 chars)")
  end

  it "truncates long tool-call arguments" do
    store.create(session_id: session[:id], role: "tool", content: "ok", tool_name: "write",
                 metadata: { arguments: { content: "y" * 500 } })

    line = markdown.lines.find { |l| l.include?("tool call") }
    expect(line).to include("…")
    expect(line.length).to be < 200
  end

  it "omits system rows entirely" do
    store.create(session_id: session[:id], role: "system", content: "[Compacted Summary]\nsecret scaffolding")
    expect(markdown).not_to include("scaffolding")
  end

  describe "#write" do
    around do |example|
      Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
    end

    it "defaults to ./rubino-session-<id8>.md and returns the absolute path" do
      path = exporter.write
      expect(path).to eq(File.expand_path("rubino-session-#{session[:id][0, 8]}.md"))
      expect(File.read(path)).to start_with("# rubino session")
    end

    it "writes to an explicit path" do
      path = exporter.write("custom.md")
      expect(path).to eq(File.expand_path("custom.md"))
      expect(File).to exist(path)
    end
  end
end
