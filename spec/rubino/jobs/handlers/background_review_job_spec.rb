# frozen_string_literal: true

require "spec_helper"

# The Hermes-style post-turn review fork — the SINGLE extraction mechanism for
# BOTH memory and skills. These specs cover the GATING and ORCHESTRATION
# deterministically (the actual model turn is stubbed): it skips cleanly when
# there is nothing to review, and when it does run it forks a child session
# seeded from the parent, restricts dispatch to the skill/memory tools via
# Rubino.review_toolset, pins the parent's captured system prompt + live
# provider, and cleans up the child afterwards. The `surfaces:` payload selects
# which halves run, intersected with the config-enabled surfaces.
RSpec.describe Rubino::Jobs::Handlers::BackgroundReviewJob do
  let(:db)     { test_database }
  let(:config) { test_configuration }

  before do
    allow(Rubino).to receive_messages(database: db, configuration: config)
  end

  def parent_with_answer
    repo  = Rubino::Session::Repository.new
    store = Rubino::Session::Store.new
    session = repo.create(source: "cli", model: "deepseek-v4-flash", provider: "deepseek")
    store.create(session_id: session[:id], role: "user", content: "do a thing")
    store.create(session_id: session[:id], role: "assistant", content: "done")
    session
  end

  # A config with the two review surfaces explicitly toggled.
  def config_with(memory:, skills:)
    test_configuration(
      "memory" => { "enabled" => true, "auto_extract" => memory },
      "skills" => { "enabled" => true, "auto_distill" => skills }
    )
  end

  it "does nothing without a session id" do
    expect(Rubino::Agent::Runner).not_to receive(:new)
    expect(described_class.new.perform({})).to be_nil
  end

  it "skips when the turn produced no assistant answer" do
    repo  = Rubino::Session::Repository.new
    store = Rubino::Session::Store.new
    session = repo.create(source: "cli")
    store.create(session_id: session[:id], role: "user", content: "hi")
    allow(Rubino::Context::PromptAssembler).to receive(:system_prompt_for).and_return("SYS")

    expect(Rubino::Agent::Runner).not_to receive(:new)
    described_class.new.perform({ session_id: session[:id] })
  end

  it "skips (no eviction risk) when no system prompt was captured for the session" do
    session = parent_with_answer
    allow(Rubino::Context::PromptAssembler).to receive(:system_prompt_for).and_return(nil)

    expect(Rubino::Agent::Runner).not_to receive(:new)
    described_class.new.perform({ session_id: session[:id] })
  end

  it "forks a skill-restricted review runner with the pinned prompt+provider, then removes the child" do
    session = parent_with_answer
    allow(Rubino::Context::PromptAssembler).to receive(:system_prompt_for).and_return("PINNED-SYS")

    seen_toolset = nil
    runner = instance_double(Rubino::Agent::Runner)
    allow(runner).to receive(:run!) { seen_toolset = Rubino.review_toolset }

    child_id = nil
    expect(Rubino::Agent::Runner).to receive(:new) do |**kwargs|
      child_id = kwargs[:session_id]
      expect(kwargs[:system_prompt_override]).to eq("PINNED-SYS")
      # the LIVE runtime provider (config), NOT the cosmetic session label
      expect(kwargs[:provider_override]).to eq(config.dig("model", "provider"))
      expect(kwargs[:interactive]).to be(false)
      runner
    end

    described_class.new.perform({ session_id: session[:id] })

    # dispatch was restricted to the skill tool during the review run…
    expect(seen_toolset).to include("skill")
    # …the child was seeded from the parent (a distinct id) and destroyed after
    expect(child_id).not_to eq(session[:id])
    expect(Rubino::Session::Repository.new.find(child_id)).to be_nil
    # and review_toolset is unbound again once the job returns
    expect(Rubino.review_toolset).to be_nil
  end

  it "uses the LIVE provider from the payload (CLI --provider) over the config default" do
    # Regression: a `--provider gateway --model <local>` turn must run the review
    # on "gateway", NOT the config default. Threading the live provider through
    # the payload is what stops the review misrouting to the native default
    # (e.g. deepseek), failing the retry ladder, and hanging inline shutdown.
    session = parent_with_answer
    allow(Rubino::Context::PromptAssembler).to receive(:system_prompt_for).and_return("SYS")

    seen_provider = nil
    runner = instance_double(Rubino::Agent::Runner)
    allow(runner).to receive(:run!)
    allow(Rubino::Agent::Runner).to receive(:new) do |**kwargs|
      seen_provider = kwargs[:provider_override]
      runner
    end

    described_class.new.perform({ session_id: session[:id], provider: "gateway" })

    expect(seen_provider).to eq("gateway")
    expect(seen_provider).not_to eq(config.dig("model", "provider"))
  end

  it "falls back to the config provider when no live provider is in the payload" do
    session = parent_with_answer
    allow(Rubino::Context::PromptAssembler).to receive(:system_prompt_for).and_return("SYS")

    seen_provider = nil
    runner = instance_double(Rubino::Agent::Runner)
    allow(runner).to receive(:run!)
    allow(Rubino::Agent::Runner).to receive(:new) do |**kwargs|
      seen_provider = kwargs[:provider_override]
      runner
    end

    described_class.new.perform({ session_id: session[:id] })

    expect(seen_provider).to eq(config.dig("model", "provider"))
  end

  it "runs ONE combined turn (skill + memory in a single prompt) when both surfaces are enabled" do
    session = parent_with_answer
    allow(Rubino).to receive(:configuration).and_return(config_with(memory: true, skills: true))
    allow(Rubino::Context::PromptAssembler).to receive(:system_prompt_for).and_return("SYS")

    prompts  = []
    toolsets = []
    runner = instance_double(Rubino::Agent::Runner)
    allow(runner).to receive(:run!) do |prompt|
      prompts << prompt
      toolsets << Rubino.review_toolset
    end
    allow(Rubino::Agent::Runner).to receive(:new).and_return(runner)

    described_class.new.perform({ session_id: session[:id] })

    # A single combined pass — NOT two separate focused turns — so the model
    # routes corrections to skills and identity facts to memory in one shot.
    expect(prompts).to eq([described_class::COMBINED_REVIEW_PROMPT])
    # it still executes under one restricted toolset carrying skill AND memory
    expect(toolsets.last).to include("skill", "memory")
  end

  it "runs ONLY the requested surface (memory) even when skills are also enabled" do
    session = parent_with_answer
    allow(Rubino).to receive(:configuration).and_return(config_with(memory: true, skills: true))
    allow(Rubino::Context::PromptAssembler).to receive(:system_prompt_for).and_return("SYS")

    prompts = []
    toolset = nil
    runner = instance_double(Rubino::Agent::Runner)
    allow(runner).to receive(:run!) do |prompt|
      prompts << prompt
      toolset = Rubino.review_toolset
    end
    allow(Rubino::Agent::Runner).to receive(:new).and_return(runner)

    described_class.new.perform({ session_id: session[:id], surfaces: ["memory"] })

    expect(prompts).to eq([described_class::MEMORY_REVIEW_PROMPT])
    expect(toolset).to include("memory")
    expect(toolset).not_to include("skill")
  end

  it "skips entirely when the requested surface is disabled in config" do
    session = parent_with_answer
    allow(Rubino).to receive(:configuration).and_return(config_with(memory: false, skills: true))
    allow(Rubino::Context::PromptAssembler).to receive(:system_prompt_for).and_return("SYS")

    # memory requested but auto_extract off, skill enabled but NOT requested.
    expect(Rubino::Agent::Runner).not_to receive(:new)
    described_class.new.perform({ session_id: session[:id], surfaces: ["memory"] })
  end

  it "binds the PARENT session id as memory_source_session_id during the review" do
    session = parent_with_answer
    allow(Rubino::Context::PromptAssembler).to receive(:system_prompt_for).and_return("SYS")

    captured_source = nil
    runner = instance_double(Rubino::Agent::Runner)
    allow(runner).to receive(:run!) do
      captured_source = Rubino.memory_source_session_id
    end
    allow(Rubino::Agent::Runner).to receive(:new).and_return(runner)

    described_class.new.perform({ session_id: session[:id], surfaces: ["memory"] })

    # The memory source must be the PARENT (driving) session, not the child.
    expect(captured_source).to eq(session[:id])
    # After the review, memory_source_session_id is cleaned up.
    expect(Rubino.memory_source_session_id).to be_nil
  end

  it "defaults to both surfaces when nil (combined prompt, both tools allowed)" do
    session = parent_with_answer
    allow(Rubino).to receive(:configuration).and_return(config_with(memory: true, skills: true))
    allow(Rubino::Context::PromptAssembler).to receive(:system_prompt_for).and_return("SYS")

    prompts = []
    toolset = nil
    runner = instance_double(Rubino::Agent::Runner)
    allow(runner).to receive(:run!) do |prompt|
      prompts << prompt
      toolset = Rubino.review_toolset
    end
    allow(Rubino::Agent::Runner).to receive(:new).and_return(runner)

    # No explicit surfaces → nil → defaults to both.
    described_class.new.perform({ session_id: session[:id] })

    expect(prompts).to eq([described_class::COMBINED_REVIEW_PROMPT])
    expect(toolset).to include("skill", "memory")
  end

  it "swallows a runner failure and still cleans up the child" do
    session = parent_with_answer
    allow(Rubino::Context::PromptAssembler).to receive(:system_prompt_for).and_return("SYS")

    child_id = nil
    runner = instance_double(Rubino::Agent::Runner)
    allow(runner).to receive(:run!).and_raise(Rubino::Error, "boom")
    allow(Rubino::Agent::Runner).to receive(:new) do |**kwargs|
      child_id = kwargs[:session_id]
      runner
    end

    expect { described_class.new.perform({ session_id: session[:id] }) }.not_to raise_error
    expect(Rubino::Session::Repository.new.find(child_id)).to be_nil
  end
end
