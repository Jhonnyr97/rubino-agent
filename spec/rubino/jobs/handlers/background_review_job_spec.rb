# frozen_string_literal: true

require "spec_helper"

# The Hermes-style post-turn skill review fork. These specs cover the GATING
# and ORCHESTRATION deterministically (the actual model turn is stubbed): it
# skips cleanly when there is nothing to review, and when it does run it forks a
# child session seeded from the parent, restricts dispatch to the skill tool via
# Rubino.review_toolset, pins the parent's captured system prompt + live
# provider, and cleans up the child afterwards.
RSpec.describe Rubino::Jobs::Handlers::BackgroundReviewJob do
  let(:db)     { test_database }
  let(:config) { test_configuration }

  before do
    allow(Rubino).to receive(:database).and_return(db)
    allow(Rubino).to receive(:configuration).and_return(config)
  end

  def parent_with_answer
    repo  = Rubino::Session::Repository.new
    store = Rubino::Session::Store.new
    session = repo.create(source: "cli", model: "deepseek-v4-flash", provider: "deepseek")
    store.create(session_id: session[:id], role: "user", content: "do a thing")
    store.create(session_id: session[:id], role: "assistant", content: "done")
    session
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
