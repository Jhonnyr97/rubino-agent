# frozen_string_literal: true

# Covers the `/model` slash command in Commands::Executor — the in-chat model
# picker. The switch writes model.default on the live configuration, persists
# it through Config::Writer (the same path /think uses), retargets the live
# runner via Runner#switch_model! so the NEXT turn hits the new model, and
# resets the session-scoped thinking-rejection memo so a provider switch never
# wedges thinking state.
RSpec.describe Rubino::Commands::Executor do
  subject(:exec) { described_class.new(loader: loader, ui: ui, runner: runner) }

  let(:ui)          { Rubino::UI::Null.new }
  let(:loader)      { Rubino::Commands::Loader.new(config: test_configuration) }
  let(:config_path) { Rubino::Config::Loader.new.config_path }

  let(:runner) do
    instance_double(Rubino::Agent::Runner,
                    session: { id: "sess-1", model: "gpt-4.1" },
                    switch_model!: nil)
  end

  # /model writes through to config.yml — scrub so a persisted switch can't
  # leak into later examples via the per-example configuration reload. The
  # thinking memo is process state, so clear that too.
  after do
    FileUtils.rm_f(config_path)
    Rubino::LLM::ThinkingSupport.reset!
  end

  describe "switching" do
    it "writes model.default on the live configuration and persists it" do
      result = exec.try_execute("/model claude-sonnet-4-5")

      expect(result).to eq(:handled)
      expect(Rubino.configuration.dig("model", "default")).to eq("claude-sonnet-4-5")
      written = YAML.safe_load_file(config_path)
      expect(written.dig("model", "default")).to eq("claude-sonnet-4-5")
    end

    it "retargets the LIVE runner so the next turn uses the new model" do
      exec.try_execute("/model claude-sonnet-4-5")
      expect(runner).to have_received(:switch_model!).with("claude-sonnet-4-5")
    end

    it "resets the session thinking-rejection memo on switch" do
      Rubino::LLM::ThinkingSupport.mark_unsupported!("minimax")
      exec.try_execute("/model claude-sonnet-4-5")
      expect(Rubino::LLM::ThinkingSupport.unsupported?("minimax")).to be(false)
    end

    it "confirms the switch with previous → new" do
      exec.try_execute("/model claude-sonnet-4-5")
      msg = ui.messages.find { |m| m[:level] == :success }
      expect(msg[:message]).to include("gpt-4.1 → claude-sonnet-4-5")
    end

    it "no-ops (with a hint) when the model is already active" do
      exec.try_execute("/model gpt-4.1")
      expect(runner).not_to have_received(:switch_model!)
      expect(ui.messages.map { |m| m[:message].to_s }.join).to include("Already on gpt-4.1")
    end

    it "still switches config-only when no runner is attached (non-interactive)" do
      bare = described_class.new(loader: loader, ui: ui)
      expect(bare.try_execute("/model gpt-5.2")).to eq(:handled)
      expect(Rubino.configuration.dig("model", "default")).to eq("gpt-5.2")
    end

    it "REJECTS a switch under a pinned catalog-less provider (label would lie) — F3" do
      Rubino.configuration.set("model", "provider", "minimax")
      # minimax isn't a registry provider → no catalog to enumerate.
      allow(Rubino::LLM::ModelCatalog).to receive(:ids_for).with("minimax").and_return([])

      exec.try_execute("/model claude-sonnet-4-5")

      # Not persisted, runner not retargeted, footer (status_model) unchanged.
      expect(runner).not_to have_received(:switch_model!)
      expect(Rubino.configuration.dig("model", "default")).not_to eq("claude-sonnet-4-5")
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("requests would still route to 'minimax'")
      expect(err[:message]).to include("Not switched")
    end

    it "REJECTS an unknown id when the provider HAS a catalog (typo guard) — F3" do
      allow(Rubino::LLM::ModelCatalog).to receive(:ids_for)
        .with("openai").and_return(%w[gpt-4.1 gpt-5.2])

      exec.try_execute("/model gpt4")

      expect(runner).not_to have_received(:switch_model!)
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("not a known model for provider 'openai'")
    end

    it "ALLOWS a catalogued id and confirms the switch" do
      allow(Rubino::LLM::ModelCatalog).to receive(:ids_for)
        .with("openai").and_return(%w[gpt-4.1 gpt-5.2])

      exec.try_execute("/model gpt-5.2")

      expect(runner).to have_received(:switch_model!).with("gpt-5.2")
    end
  end

  describe "bare /model" do
    it "shows the current model + provider and the registry models for it" do
      allow(Rubino::LLM::ModelCatalog).to receive(:ids_for)
        .with("openai").and_return(%w[gpt-4.1 gpt-5.2])

      exec.try_execute("/model")

      out = ui.messages.map { |m| m[:message].to_s }.join("\n")
      expect(out).to include("Current model: gpt-4.1 (provider: openai)")
      expect(out).to include("▸ /model gpt-4.1")
      expect(out).to include("/model gpt-5.2")
    end

    it "degrades to a usage hint when an UNPINNED provider isn't enumerable" do
      allow(Rubino::LLM::ModelCatalog).to receive(:ids_for).and_return([])

      exec.try_execute("/model")

      out = ui.messages.map { |m| m[:message].to_s }.join("\n")
      expect(out).to include("still switches (the id picks the provider)")
    end

    it "warns the id is a label-only when a PINNED provider isn't enumerable" do
      Rubino.configuration.set("model", "provider", "minimax")
      allow(Rubino::LLM::ModelCatalog).to receive(:ids_for).and_return([])

      exec.try_execute("/model")

      out = ui.messages.map { |m| m[:message].to_s }.join("\n")
      expect(out).to include("pinned and has no model catalog")
      expect(out).to include("won't change the backend")
    end

    it "caps the listing and defers the rest to the dropdown" do
      allow(Rubino::LLM::ModelCatalog).to receive(:ids_for)
        .and_return((1..20).map { |i| "gpt-#{i}" })

      exec.try_execute("/model")

      out = ui.messages.map { |m| m[:message].to_s }.join("\n")
      expect(out).to include("and 8 more")
    end
  end

  it "registers /model as a discoverable built-in" do
    expect(Rubino::Commands::BuiltIns::NAMES).to include("/model")
  end
end
