# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Rubino::CLI::OnboardingWizard do
  let(:home)   { Dir.mktmpdir("ra-onboard") }
  let(:ui)     { Rubino::UI::Null.new }
  let(:output) { StringIO.new }

  around do |ex|
    prev = ENV["RUBINO_HOME"]
    ENV["RUBINO_HOME"] = home
    saved_keys = ENV.to_hash.slice("MINIMAX_API_KEY", "OPENAI_API_KEY")
    %w[MINIMAX_API_KEY OPENAI_API_KEY].each { |k| ENV.delete(k) }
    ex.run
  ensure
    ENV["RUBINO_HOME"] = prev
    %w[MINIMAX_API_KEY OPENAI_API_KEY].each { |k| ENV.delete(k) }
    saved_keys.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(home)
  end

  def wizard(script)
    described_class.new(ui: ui, input: StringIO.new(script), output: output)
  end

  it "writes a usable MiniMax config + .env from scripted input (choice 1)" do
    # "1" = MiniMax, then the key (no base_url prompt — MiniMax has a default).
    ok = wizard("1\nsk-minimax-test\n").run
    expect(ok).to be true

    loader = Rubino::Config::Loader.new(home_path: home)
    raw    = YAML.safe_load(File.read(loader.config_path))
    expect(raw.dig("model", "default")).to eq("MiniMax-M2.7")
    expect(raw.dig("model", "provider")).to eq("minimax")
    expect(raw.dig("providers", "minimax", "anthropic_compatible")).to be true
    expect(raw.dig("providers", "minimax", "api_key")).to eq("${MINIMAX_API_KEY}")

    env = File.read(loader.env_path)
    expect(env).to include("MINIMAX_API_KEY=sk-minimax-test")

    # The config the agent loads is now usable (key visible in ENV + config).
    config = Rubino::Config::Configuration.new(raw: loader.load)
    expect(Rubino::LLM::CredentialCheck.usable?(config)).to be true
  end

  it "writes an OpenAI config (choice 2)" do
    ok = wizard("2\nsk-openai-test\n").run
    expect(ok).to be true

    loader = Rubino::Config::Loader.new(home_path: home)
    raw    = YAML.safe_load(File.read(loader.config_path))
    expect(raw.dig("model", "provider")).to eq("openai")
    expect(File.read(loader.env_path)).to include("OPENAI_API_KEY=sk-openai-test")
  end

  it "returns false (and writes nothing) when the user skips at the provider prompt" do
    ok = wizard("\n").run
    expect(ok).to be false
    expect(File.exist?(Rubino::Config::Loader.new(home_path: home).config_path)).to be false
  end

  it "returns false when the user provides an empty key" do
    ok = wizard("1\n\n").run
    expect(ok).to be false
  end

  it "does not echo the API key back to the output stream" do
    wizard("1\nsk-super-secret\n").run
    expect(output.string).not_to include("sk-super-secret")
  end
end
