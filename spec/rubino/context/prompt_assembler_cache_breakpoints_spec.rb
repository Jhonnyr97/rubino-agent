# frozen_string_literal: true

require "digest"

# #311 — prompt-cache breakpoints. On the anthropic-family path the system
# message is emitted as a Content::Raw array whose STABLE PREFIX block carries a
# cache_control breakpoint and whose VOLATILE TAIL block (fresh relevant-memories
# + post-compaction session-summary) sits AFTER it — so the cached prefix bytes
# stay byte-stable across turns even as the tail changes.
RSpec.describe Rubino::Context::PromptAssembler, "cache breakpoints (#311)" do
  let(:session) { { id: "sess-cache-#{SecureRandom.hex(4)}", model: "anthropic/claude-sonnet-4" } }
  let(:empty_memory) { { user_profile: "", relevant_memories: [] } }

  # An anthropic-provider config so the cache wire-shape (Content::Raw) is active.
  def anthropic_config(overrides = {})
    test_configuration({ "model" => { "default" => "anthropic/claude-sonnet-4",
                                      "provider" => "anthropic" } }.merge(overrides))
  end

  # An openai-provider config — caching must NOT change the String contract.
  def openai_config
    test_configuration("model" => { "default" => "openai/gpt-4.1", "provider" => "openai" })
  end

  before do
    described_class.reset_all_snapshots!
    Rubino::Context::EnvironmentInspector.reset_cache!
    allow_any_instance_of(Rubino::Session::Store).to receive(:for_session).and_return([])
    allow_any_instance_of(Rubino::Session::SummaryStore).to receive(:latest_content).and_return(nil)
    with_test_db
  end

  def assembler(config:, memory: empty_memory)
    described_class.new(session: session, memory_context: memory, config: config)
  end

  describe "anthropic-family wire shape" do
    it "emits the system block as a Content::Raw array" do
      content = assembler(config: anthropic_config).build.first[:content]
      expect(content).to be_a(RubyLLM::Content::Raw)
      expect(content.value).to be_an(Array)
    end

    it "puts a cache_control breakpoint on the stable prefix block" do
      blocks = assembler(config: anthropic_config).build.first[:content].value
      prefix = blocks.first
      expect(prefix[:type]).to eq("text")
      expect(prefix[:cache_control]).to eq({ type: "ephemeral" })
      expect(prefix[:text]).to include("[Identity]")
    end

    it "keeps relevant-memories OUT of the cached prefix (volatile tail, no breakpoint)" do
      memory = { user_profile: "", relevant_memories: [{ content: "MEM-MARKER" }] }
      blocks = assembler(config: anthropic_config, memory: memory).build.first[:content].value

      prefix = blocks.first
      expect(prefix[:text]).not_to include("MEM-MARKER")

      tail = blocks.last
      expect(tail[:cache_control]).to be_nil
      expect(tail[:text]).to include("[Relevant Memories]")
      expect(tail[:text]).to include("MEM-MARKER")
    end

    it "keeps the post-compaction session-summary OUT of the cached prefix" do
      allow_any_instance_of(Rubino::Session::SummaryStore)
        .to receive(:latest_content).and_return("SUMMARY-MARKER")
      blocks = assembler(config: anthropic_config).build.first[:content].value
      expect(blocks.first[:text]).not_to include("SUMMARY-MARKER")
      expect(blocks.last[:text]).to include("[Session Summary]\nSUMMARY-MARKER")
    end

    it "ships only the single cached prefix block when there is no tail" do
      blocks = assembler(config: anthropic_config).build.first[:content].value
      expect(blocks.size).to eq(1)
      expect(blocks.first[:cache_control]).to eq({ type: "ephemeral" })
    end
  end

  describe "prefix byte-stability across turns" do
    it "md5 of the cached prefix bytes is identical on turn 1 and turn 2, even as the tail grows" do
      config = anthropic_config

      # Turn 1: no summary, no memories.
      prefix1 = assembler(config: config).build.first[:content].value.first[:text]

      # Turn 2 (same session): a relevance-aware backend injects a memory AND a
      # mid-session compaction wrote a summary — both land in the VOLATILE tail.
      allow_any_instance_of(Rubino::Session::SummaryStore)
        .to receive(:latest_content).and_return("a fresh summary appeared mid-session")
      memory = { user_profile: "", relevant_memories: [{ content: "a freshly-retrieved memory" }] }
      content2 = assembler(config: config, memory: memory).build.first[:content].value
      prefix2 = content2.first[:text]

      expect(Digest::MD5.hexdigest(prefix2)).to eq(Digest::MD5.hexdigest(prefix1))
      # ...and the tail did change (so the test is meaningful).
      expect(content2.last[:text]).to include("a fresh summary appeared mid-session")
    end
  end

  describe "no regression / portability" do
    it "the cached Raw renders the same bytes as the cache-disabled String path" do
      memory = { user_profile: "loves zsh", relevant_memories: [{ content: "uses tmux" }] }
      allow_any_instance_of(Rubino::Session::SummaryStore)
        .to receive(:latest_content).and_return("did X")

      # Caching ON (anthropic): Content::Raw, prefix + tail blocks joined.
      raw_text = assembler(config: anthropic_config, memory: memory)
                 .build.first[:content].value.map { |b| b[:text] }.join("\n\n")

      # Caching OFF (same anthropic model, prompt_cache:false): plain String.
      disabled = anthropic_config("prompts" => Rubino::Config::Defaults.to_hash["prompts"]
                                                                       .merge("prompt_cache" => false))
      described_class.reset_all_snapshots!
      string_text = assembler(config: disabled, memory: memory).build.first[:content]

      expect(raw_text).to eq(string_text)
      # Every section is still present — nothing dropped by the split.
      expect(raw_text).to include("[Identity]")
      expect(raw_text).to include("uses tmux")
      expect(raw_text).to include("[Session Summary]\ndid X")
    end

    it "falls back to a plain String on the openai path (no cache_control keys)" do
      content = assembler(config: openai_config).build.first[:content]
      expect(content).to be_a(String)
      expect(content).to include("[Identity]")
      expect(content).not_to include("cache_control")
    end

    it "falls back to a plain String when prompt caching is disabled in config" do
      config = anthropic_config("prompts" => Rubino::Config::Defaults.to_hash["prompts"]
                                                                     .merge("prompt_cache" => false))
      content = assembler(config: config).build.first[:content]
      expect(content).to be_a(String)
    end
  end
end
