# frozen_string_literal: true

# Behaviour spec for the ephemeral `probe` side-question (the principal-chat
# counterpart of the subagent probe). The contract under test:
#   - it runs a ONE-SHOT side-inference over a SNAPSHOT of the session's
#     messages + the question, with NO tools;
#   - it returns the answer;
#   - it does NOT mutate the session message store (screen-only, vanishes).
RSpec.describe Rubino::Interaction::Probe do
  let(:db)     { test_database }
  let(:config) { test_configuration }
  let(:store)  { Rubino::Session::Store.new(db: db.db) }
  let(:repo)   { Rubino::Session::Repository.new(db: db.db) }

  let(:session) do
    s = repo.create(source: "cli", model: "fake/test", provider: "fake")
    s[:persisted] = true
    s
  end

  before do
    allow(Rubino).to receive(:database).and_return(db)
    allow(Rubino).to receive(:configuration).and_return(config)
    # Seed a couple of real turns so the snapshot has history to read.
    store.create(session_id: session[:id], role: "user", content: "wire up billing")
    store.create(session_id: session[:id], role: "assistant", content: "On it.")
  end

  subject(:probe) do
    described_class.new(session: session, config: config,
                        model_override: "fake/test", provider_override: "fake")
  end

  it "runs a one-shot side-inference (no tools) over the session snapshot + question" do
    captured = nil
    adapter  = instance_double(Rubino::LLM::FakeProvider)
    allow(adapter).to receive(:chat) do |messages:, tools:|
      captured = { messages: messages, tools: tools }
      Rubino::LLM::AdapterResponse.new(
        content: "MIT.", tool_calls: [], input_tokens: 1, output_tokens: 1, model_id: "fake/test"
      )
    end
    allow(Rubino::LLM::AdapterFactory).to receive(:build).and_return(adapter)

    result = probe.ask("is this lib MIT or GPL?")

    expect(result.answer).to eq("MIT.")
    expect(result.question).to eq("is this lib MIT or GPL?")
    # Read-only: no tools are offered to the side-inference.
    expect(captured[:tools]).to be_nil
    # The snapshot carries the session history, and the question is the LAST
    # (user) message appended on top of it.
    contents = captured[:messages].map { |m| m[:content] || m["content"] }
    expect(contents).to include("wire up billing")
    expect(captured[:messages].last[:content]).to eq("is this lib MIT or GPL?")
    expect(captured[:messages].last[:role]).to eq("user")
  end

  it "does NOT append the question or answer to the session message store" do
    adapter = instance_double(
      Rubino::LLM::FakeProvider,
      chat: Rubino::LLM::AdapterResponse.new(
        content: "MIT.", tool_calls: [], input_tokens: 1, output_tokens: 1, model_id: "fake/test"
      )
    )
    allow(Rubino::LLM::AdapterFactory).to receive(:build).and_return(adapter)

    before_ids = store.for_session(session[:id]).map(&:id)
    probe.ask("is this lib MIT or GPL?")
    after = store.for_session(session[:id])

    # The store is byte-for-byte unchanged: same rows, same count.
    expect(after.map(&:id)).to eq(before_ids)
    expect(after.map(&:content)).to eq(["wire up billing", "On it."])
  end
end
