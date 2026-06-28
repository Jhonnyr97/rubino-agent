# frozen_string_literal: true

# Tool-use-enforcement + memory-discipline steering (ported from Hermes
# prompt_builder.py). The open-weight models rubino targets narrate-instead-of-
# act and leak tool-calls as text without this; the config key existed but its
# injection was dropped in the port (#588 dead key). These specs prove the
# injection is wired and model-gated.
RSpec.describe Rubino::Context::PromptAssembler do
  let(:session) { { id: "sess-tue-#{SecureRandom.hex(4)}" } }
  let(:empty_memory) { { user_profile: "", relevant_memories: [] } }

  before do
    described_class.reset_all_snapshots!
    Rubino::Context::EnvironmentInspector.reset_cache!
    allow(Rubino::Session::Store).to receive(:new)
      .and_return(instance_double(Rubino::Session::Store, for_session: []))
    with_test_db
  end

  def prompt_for(model, enforcement: nil, memory_enabled: nil)
    config = test_configuration
    config.set("model", "default", model)
    config.set("agent", "tool_use_enforcement", enforcement) unless enforcement.nil?
    config.set("memory", "enabled", memory_enabled) unless memory_enabled.nil?
    described_class.new(session: session, memory_context: empty_memory, config: config)
                   .build.first[:content].to_s
  end

  describe "auto (default) — model-family gated" do
    it "injects enforcement for an open-weight model (deepseek, the default target)" do
      expect(prompt_for("deepseek-v4-flash")).to include("Tool-use enforcement")
        .and include("you MUST immediately make the corresponding tool call")
    end

    it "injects enforcement for minimax (rubino-added to the list)" do
      expect(prompt_for("MiniMax-M3")).to include("Tool-use enforcement")
    end

    it "does NOT inject for a strong-FC model (claude)" do
      expect(prompt_for("claude-opus-4")).not_to include("Tool-use enforcement")
    end
  end

  describe "per-family operational guidance" do
    it "adds the Google directives for gemini/gemma" do
      out = prompt_for("gemini-2.0-flash")
      expect(out).to include("Tool-use enforcement").and include("Google model operational directives")
      expect(out).not_to include("Execution discipline") # not the OpenAI block
    end

    it "adds the OpenAI execution discipline for gpt/codex/grok" do
      out = prompt_for("gpt-4.1")
      expect(out).to include("Tool-use enforcement").and include("Execution discipline")
      expect(out).not_to include("Google model operational directives")
    end
  end

  describe "config override" do
    it "true forces injection even for a strong-FC model" do
      expect(prompt_for("claude-opus-4", enforcement: true)).to include("Tool-use enforcement")
    end

    it "false suppresses it even for an open-weight model" do
      expect(prompt_for("deepseek-v4-flash", enforcement: false)).not_to include("Tool-use enforcement")
    end

    it "an explicit substring list matches the model id" do
      expect(prompt_for("some-custom-model", enforcement: ["custom"])).to include("Tool-use enforcement")
      expect(prompt_for("some-other-model", enforcement: ["custom"])).not_to include("Tool-use enforcement")
    end
  end

  describe "memory discipline" do
    it "injects the memory-write guidance when memory is enabled (default)" do
      expect(prompt_for("deepseek-v4-flash")).to include("Memory discipline")
        .and include("declarative facts, not instructions")
    end

    it "omits it when memory is disabled" do
      expect(prompt_for("deepseek-v4-flash", memory_enabled: false)).not_to include("Memory discipline")
    end
  end
end
