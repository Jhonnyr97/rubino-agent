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

  # FIX 1 — volatile_tail reads LIVE per-turn @memory_context, NOT the frozen
  # turn-1 snapshot. [User Profile] stays frozen in stable_prefix (anti-
  # poisoning); [Relevant Memories] must reflect the CURRENT turn's retrieval.
  describe "volatile_tail reads live @memory_context" do
    it "surfaces turn-2 relevant memories, not the frozen turn-1 set" do
      session_id = "sess-volatile-#{SecureRandom.hex(4)}"
      sess = { id: session_id }

      # Turn 1
      described_class.new(
        session: sess,
        memory_context: {
          user_profile: "loves zsh",
          relevant_memories: [{ id: "m1", kind: "fact", content: "turn-1 memory about python" }]
        },
        config: config
      ).build

      # Turn 2 — fresh retrieval from a different query
      messages2 = described_class.new(
        session: sess,
        memory_context: {
          user_profile: "loves zsh", # same profile (stable)
          relevant_memories: [{ id: "m2", kind: "fact", content: "turn-2 memory about rust" }]
        },
        config: config
      ).build

      content = messages2.first[:content]
      # [User Profile] is still the frozen "loves zsh"
      expect(content).to include("loves zsh")
      # [Relevant Memories] must reflect turn 2's live retrieval
      expect(content).to include("turn-2 memory about rust")
      # turn-1's memory must NOT leak through the frozen snapshot
      expect(content).not_to include("turn-1 memory about python")
    end

    it "still shows [Relevant Memories] empty when the current turn has none" do
      session_id = "sess-empty-mem-#{SecureRandom.hex(4)}"
      sess = { id: session_id }

      # Turn 1 with memories
      described_class.new(
        session: sess,
        memory_context: {
          user_profile: "prefers emacs",
          relevant_memories: [{ id: "m1", kind: "fact", content: "some memory" }]
        },
        config: config
      ).build

      # Turn 2 with empty relevant_memories
      messages2 = described_class.new(
        session: sess,
        memory_context: {
          user_profile: "prefers emacs",
          relevant_memories: []
        },
        config: config
      ).build

      content = messages2.first[:content]
      expect(content).to include("prefers emacs") # [User Profile] frozen
      # The old turn-1 memory must NOT leak through — only the static
      # memory_index_block header (which mentions [Relevant Memories]
      # generically) is present; no stale fact content.
      expect(content).not_to include("some memory")
    end
  end

  # FIX 2a — memory_index_block: an always-present framing block (like the
  # skills index) that tells the model WHAT memory is and HOW to use it.
  describe "memory index block" do
    let(:session) { { id: "sess-mem-index-#{SecureRandom.hex(4)}" } }

    def system_content_with_config(memory_enabled)
      cfg = test_configuration("memory" => { "enabled" => memory_enabled })
      described_class.new(
        session: session,
        memory_context: { user_profile: nil, relevant_memories: [] },
        config: cfg
      ).build.first[:content]
    end

    it "is present when memory is enabled" do
      content = system_content_with_config(true)
      expect(content).to include("## Memory")
      expect(content).to include("persistent memory about the user and this project")
    end

    it "is absent when memory is disabled" do
      content = system_content_with_config(false)
      expect(content).not_to include("## Memory")
    end

    it "frames memory as authoritative ground truth to answer from, over re-derivation" do
      content = system_content_with_config(true)
      expect(content).to include("authoritative ground truth")
      expect(content).to include("answer from it directly")
      # the precedence directive: don't re-investigate what memory already states
      expect(content).to include("do NOT re-read files, grep, or otherwise re-derive")
    end

    it "includes the 'search if you expect context' nudge" do
      content = system_content_with_config(true)
      expect(content).to include("search it with the memory / session_search tool")
      expect(content).to include("before assuming it doesn't exist")
    end
  end

  # FIX 2b — memory_guidance.txt now includes a "Using recalled memory" section
  # that tells the model to read + apply facts before answering.
  describe "memory guidance recall section" do
    let(:session) { { id: "sess-mem-guidance-#{SecureRandom.hex(4)}" } }

    it "includes the 'Using recalled memory' section in the guidance block" do
      cfg = test_configuration("memory" => { "enabled" => true })
      content = described_class.new(
        session: session,
        memory_context: { user_profile: nil, relevant_memories: [] },
        config: cfg
      ).build.first[:content]

      expect(content).to include("Using recalled memory")
      expect(content).to include("Read and apply recalled facts BEFORE answering")
      expect(content).to include("don't re-ask for preferences, conventions, or decisions")
    end
  end
end
