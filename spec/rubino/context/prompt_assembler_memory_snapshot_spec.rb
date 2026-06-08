# frozen_string_literal: true

RSpec.describe Rubino::Context::PromptAssembler, "memory snapshot" do
  let(:config) { test_configuration }
  let(:session) { { id: "sess-snap-#{SecureRandom.hex(4)}" } }

  before do
    described_class.reset_all_snapshots!
    allow_any_instance_of(Rubino::Session::Store).to receive(:for_session).and_return([])
  end

  def build_with(memory_context)
    described_class.new(
      session: session,
      memory_context: memory_context,
      config: config
    ).build
  end

  it "captures the memory context on first assembly" do
    messages = build_with(user_profile: "loves zsh", relevant_memories: [])
    expect(messages.first[:content]).to include("loves zsh")
  end

  it "freezes the snapshot across subsequent assemblies in the same session" do
    build_with(user_profile: "original profile", relevant_memories: [])

    # Mutate the context the second assembler sees — should be ignored
    # because the session's snapshot is already frozen.
    second = build_with(user_profile: "tampered profile", relevant_memories: [])

    expect(second.first[:content]).to include("original profile")
    expect(second.first[:content]).not_to include("tampered profile")
  end

  it "uses fresh memory after reset_snapshot!" do
    build_with(user_profile: "original profile", relevant_memories: [])
    described_class.reset_snapshot!(session[:id])

    refreshed = build_with(user_profile: "refreshed profile", relevant_memories: [])
    expect(refreshed.first[:content]).to include("refreshed profile")
  end

  it "isolates snapshots between sessions" do
    other_session = { id: "sess-other-#{SecureRandom.hex(4)}" }

    described_class.new(
      session: session,
      memory_context: { user_profile: "first session profile", relevant_memories: [] },
      config: config
    ).build

    second_messages = described_class.new(
      session: other_session,
      memory_context: { user_profile: "second session profile", relevant_memories: [] },
      config: config
    ).build

    expect(second_messages.first[:content]).to include("second session profile")
  end
end
