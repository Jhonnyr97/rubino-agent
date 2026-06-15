# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Rubino::CLI::OnboardingWizard do
  let(:home)   { Dir.mktmpdir("ra-onboard") }
  let(:ui)     { Rubino::UI::Null.new }
  let(:output) { StringIO.new }

  around do |ex|
    prev = ENV.fetch("RUBINO_HOME", nil)
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

  it "defaults to the seeded model: the first (recommended) provider is minimax/MiniMax-M3" do
    # #414: the wizard's recommended default must match the seeded
    # config/defaults.rb default (model.default => minimax/MiniMax-M3) so the
    # from-zero experience is consistent with the non-interactive fail-fast
    # guidance, which names that same default. Aligned openai → MiniMax.
    first = described_class::PROVIDERS.first
    expect(first[:provider]).to eq("minimax")
    expect(first[:model]).to eq("MiniMax-M3")

    seeded = Rubino::Config::Defaults.dig("model", "default")
    expect(seeded).to eq("minimax/MiniMax-M3")
    expect("#{first[:provider]}/#{first[:model]}").to eq(seeded)
  end

  it "keeps OpenAI as a first-class selectable option (just not the default)" do
    openai = described_class::PROVIDERS.find { |p| p[:provider] == "openai" }
    expect(openai).not_to be_nil
    expect(openai[:model]).to eq("gpt-4.1")
    expect(described_class::PROVIDERS.first).not_to eq(openai)
  end

  it "writes a usable MiniMax config + .env from scripted input (choice 1, the default)" do
    # "1" = MiniMax (the recommended default), then the key (no base_url prompt).
    ok = wizard("1\nsk-minimax-test\n").run
    expect(ok).to be true

    loader = Rubino::Config::Loader.new(home_path: home)
    raw    = YAML.safe_load_file(loader.config_path)
    expect(raw.dig("model", "default")).to eq("MiniMax-M3")
    expect(raw.dig("model", "provider")).to eq("minimax")
    expect(raw.dig("providers", "minimax", "anthropic_compatible")).to be true
    expect(raw.dig("providers", "minimax", "api_key")).to eq("${MINIMAX_API_KEY}")

    env = File.read(loader.env_path)
    expect(env).to include("MINIMAX_API_KEY=sk-minimax-test")

    # The config the agent loads is now usable (key visible in ENV + config).
    config = Rubino::Config::Configuration.new(raw: loader.load)
    expect(Rubino::LLM::CredentialCheck.usable?(config)).to be true
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

  # #31: a single invalid (out-of-range) choice must re-prompt rather than
  # abandon the wizard. Here it is out of range, then "2" (OpenAI) + a key.
  it "re-prompts on an invalid choice instead of abandoning setup" do
    n = described_class::PROVIDERS.size
    ok = wizard("#{n + 5}\n2\nsk-openai-test\n").run
    expect(ok).to be true

    # The provider prompt was shown twice (initial + re-prompt after the typo).
    prompts = output.string.scan("Choose a provider").size
    expect(prompts).to be >= 2

    loader = Rubino::Config::Loader.new(home_path: home)
    raw    = YAML.safe_load_file(loader.config_path)
    expect(raw.dig("model", "provider")).to eq("openai")
  end

  # #31: an explicit skip (Enter) at the provider prompt still bails cleanly —
  # the re-prompt loop must not trap the user when they genuinely want out.
  it "still honours an explicit skip after the loop change" do
    ok = wizard("\n").run
    expect(ok).to be false
  end
end
