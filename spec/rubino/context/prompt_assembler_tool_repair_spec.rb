# frozen_string_literal: true

# The defensive pre-send "net": PromptAssembler#build repairs tool pairing
# across the full history before emitting wire format, so sessions ALREADY
# corrupted by the historical metadata-dropping bug (orphan tool rows in prod)
# don't 400 strict providers on resume.

RSpec.describe Rubino::Context::PromptAssembler do
  let(:db_connection) { test_database }
  let(:db) { db_connection.db }
  let(:store) { Rubino::Session::Store.new(db: db) }
  let(:repo) { Rubino::Session::Repository.new(db: db) }
  let(:session) { repo.create(source: "test", model: "m", provider: "p") }

  before { allow(Rubino).to receive(:database).and_return(db_connection) }
  after { described_class.reset_all_snapshots! }

  def assembler
    described_class.new(session: { id: session[:id] }, memory_context: {}, config: Rubino.configuration)
  end

  def declared_ids(wire)
    wire.flat_map { |m| Array(m[:tool_calls]).map { |tc| tc[:id] } }.compact
  end

  def result_ids(wire)
    wire.select { |m| m[:role] == "tool" }.map { |m| m[:tool_call_id] }
  end

  it "drops a leading orphan tool_result whose call is absent" do
    store.create(session_id: session[:id], role: "tool", content: "stale", tool_call_id: "gone")
    store.create(session_id: session[:id], role: "user", content: "hi")

    wire = assembler.build
    expect(result_ids(wire)).to be_empty
  end

  it "strips tool_calls from a trailing interrupted assistant call with no result" do
    store.create(session_id: session[:id], role: "user", content: "hi")
    store.create(
      session_id: session[:id], role: "assistant", content: "working on it",
      metadata: { tool_calls: [{ id: "call_x", name: "shell", arguments: {} }] }
    )

    wire = assembler.build
    expect(declared_ids(wire)).to be_empty
    # prose preserved (assistant message kept, just without the toolUse)
    expect(wire.any? { |m| m[:role] == "assistant" && m[:content] == "working on it" }).to be true
  end

  it "drops an empty interrupted assistant call (no content, no result)" do
    store.create(session_id: session[:id], role: "user", content: "hi")
    store.create(
      session_id: session[:id], role: "assistant", content: "",
      metadata: { tool_calls: [{ id: "call_x", name: "shell", arguments: {} }] }
    )

    wire = assembler.build
    expect(declared_ids(wire)).to be_empty
    expect(wire.none? { |m| m[:role] == "assistant" }).to be true
  end

  it "leaves a properly paired history with no orphans" do
    store.create(session_id: session[:id], role: "user", content: "hi")
    store.create(
      session_id: session[:id], role: "assistant", content: "calling",
      metadata: { tool_calls: [{ id: "call_1", name: "shell", arguments: {} }] }
    )
    store.create(session_id: session[:id], role: "tool", content: "out", tool_call_id: "call_1")

    wire = assembler.build
    expect(declared_ids(wire)).to eq(%w[call_1])
    expect(result_ids(wire) - declared_ids(wire)).to be_empty
  end
end
