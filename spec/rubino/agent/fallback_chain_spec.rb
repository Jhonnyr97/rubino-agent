# frozen_string_literal: true

RSpec.describe Rubino::Agent::FallbackChain do
  # A minimal adapter stand-in: only the bits the chain reads (provider/model_id)
  # plus a tag so specs can assert WHICH adapter is active. No ruby_llm, no
  # network, no global config.
  FakeAdapter = Struct.new(:provider, :model_id, :tag, keyword_init: true)

  # Records every build call and returns a tagged FakeAdapter, so a spec can
  # assert the chain rebuilt via the factory with the right entry.
  class RecordingBuilder
    attr_reader :builds

    def initialize
      @builds = []
    end

    def build(model_id:, provider:, isolate_config:, **_rest)
      @builds << { model_id: model_id, provider: provider, isolate_config: isolate_config }
      FakeAdapter.new(provider: provider, model_id: model_id, tag: :fallback)
    end
  end

  let(:primary)  { FakeAdapter.new(provider: "openai", model_id: "gpt-4.1", tag: :primary) }
  let(:builder)  { RecordingBuilder.new }
  let(:ui)       { Rubino::UI::Null.new }

  def build_chain(fallbacks)
    described_class.new(
      primary_adapter: primary,
      config: test_configuration("agent" => { "fallback_models" => fallbacks }),
      ui: ui,
      adapter_builder: builder
    )
  end

  describe "with no fallbacks configured (the no-op case)" do
    subject(:chain) { build_chain([]) }

    it "starts on the primary" do
      expect(chain.current_adapter).to be(primary)
      expect(chain.active?).to be(false)
    end

    it "activate_next! is false and changes nothing" do
      expect(chain.activate_next!).to be(false)
      expect(chain.current_adapter).to be(primary)
      expect(builder.builds).to be_empty
    end
  end

  describe "#activate_next!" do
    subject(:chain) do
      build_chain([
                    { "provider" => "anthropic", "model" => "claude-x" },
                    { "provider" => "gemini",    "model" => "gemini-y" }
                  ])
    end

    it "advances to the first fallback and rebuilds via the factory" do
      expect(chain.activate_next!).to be(true)
      expect(chain.current_adapter.provider).to eq("anthropic")
      expect(chain.current_adapter.model_id).to eq("claude-x")
      expect(chain.active?).to be(true)
      expect(builder.builds.first).to include(model_id: "claude-x", provider: "anthropic")
    end

    it "builds fallback adapters with isolate_config: true (no global mutation)" do
      chain.activate_next!
      expect(builder.builds.first[:isolate_config]).to be(true)
    end

    it "advances through each entry on successive calls, then exhausts" do
      expect(chain.activate_next!).to be(true)
      expect(chain.current_adapter.provider).to eq("anthropic")
      expect(chain.activate_next!).to be(true)
      expect(chain.current_adapter.provider).to eq("gemini")
      expect(chain.activate_next!).to be(false) # exhausted
      expect(chain.current_adapter.provider).to eq("gemini") # stays on last
    end
  end

  describe "dedup of the current backend" do
    it "skips an entry resolving to the current provider/model" do
      chain = build_chain([
                            { "provider" => "openai", "model" => "gpt-4.1" }, # == primary, skip
                            { "provider" => "anthropic", "model" => "claude-x" }
                          ])
      expect(chain.activate_next!).to be(true)
      # Jumped straight past the duplicate to the anthropic entry.
      expect(chain.current_adapter.provider).to eq("anthropic")
      expect(builder.builds.map { |b| b[:provider] }).to eq(["anthropic"])
    end

    it "skips an entry whose base_url matches the current backend (same model)" do
      # Primary points at a custom openai base_url via provider config.
      cfg = test_configuration(
        "providers" => { "openai" => { "base_url" => "https://proxy.test/v1" } },
        "agent" => { "fallback_models" => [
          { "provider" => "openai", "model" => "gpt-4.1", "base_url" => "https://proxy.test/v1/" },
          { "provider" => "anthropic", "model" => "claude-x" }
        ] }
      )
      chain = described_class.new(primary_adapter: primary, config: cfg, ui: ui,
                                  adapter_builder: builder)
      expect(chain.activate_next!).to be(true)
      expect(chain.current_adapter.provider).to eq("anthropic")
    end

    it "skips invalid entries (missing provider or model)" do
      chain = build_chain([
                            { "provider" => "anthropic" },           # no model, skip
                            { "model" => "gemini-y" },               # no provider, skip
                            { "provider" => "gemini", "model" => "gemini-y" }
                          ])
      expect(chain.activate_next!).to be(true)
      expect(chain.current_adapter.provider).to eq("gemini")
      expect(builder.builds.size).to eq(1)
    end
  end

  describe "#restore_primary!" do
    subject(:chain) { build_chain([{ "provider" => "anthropic", "model" => "claude-x" }]) }

    it "resets to the primary at index 0" do
      chain.activate_next!
      expect(chain.current_adapter.provider).to eq("anthropic")

      chain.restore_primary!
      expect(chain.current_adapter).to be(primary)
      expect(chain.active?).to be(false)
    end

    it "re-enables the chain so the next turn can fall back again" do
      chain.activate_next!
      chain.restore_primary!
      expect(chain.activate_next!).to be(true)
      expect(chain.current_adapter.provider).to eq("anthropic")
    end
  end
end
