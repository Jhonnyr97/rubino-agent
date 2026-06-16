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

  it "defaults to the seeded model: the first (recommended) provider is openai/gpt-4.1" do
    # The wizard's recommended default must match the seeded config/defaults.rb
    # default (model.default => openai/gpt-4.1) so the from-zero experience is
    # consistent with the non-interactive fail-fast guidance, which names that
    # same default (maintainer directive: OpenAI default, MiniMax not pushed).
    first = described_class::PROVIDERS.first
    expect(first[:provider]).to eq("openai")
    expect(first[:model]).to eq("gpt-4.1")

    seeded = Rubino::Config::Defaults.dig("model", "default")
    expect(seeded).to eq("openai/gpt-4.1")
    expect("#{first[:provider]}/#{first[:model]}").to eq(seeded)
  end

  it "keeps MiniMax as a first-class selectable option (just not the default)" do
    minimax = described_class::PROVIDERS.find { |p| p[:provider] == "minimax" }
    expect(minimax).not_to be_nil
    expect(minimax[:model]).to eq("MiniMax-M3")
    # Picking MiniMax must still yield a first-turn-working config: the catalog
    # carries the anthropic_compatible + base_url wiring it needs to route.
    expect(minimax[:config]["anthropic_compatible"]).to be true
    expect(minimax[:config]["base_url"]).to eq("https://api.minimax.io/anthropic")
    # Available, but NOT the recommended/auto-picked first entry.
    expect(described_class::PROVIDERS.first).not_to eq(minimax)
  end

  it "writes a usable OpenAI config + .env from scripted input (choice 1, the default)" do
    # "1" = OpenAI (the recommended default), then the key (no base_url prompt).
    ok = wizard("1\nsk-openai-test\n").run
    expect(ok).to be true

    loader = Rubino::Config::Loader.new(home_path: home)
    raw    = YAML.safe_load_file(loader.config_path)
    expect(raw.dig("model", "default")).to eq("gpt-4.1")
    expect(raw.dig("model", "provider")).to eq("openai")

    env = File.read(loader.env_path)
    expect(env).to include("OPENAI_API_KEY=sk-openai-test")

    # The config the agent loads is now usable (key visible in ENV + config).
    config = Rubino::Config::Configuration.new(raw: loader.load)
    expect(Rubino::LLM::CredentialCheck.usable?(config)).to be true
  end

  it "writes a usable MiniMax config + .env when MiniMax is chosen (choice 2)" do
    # "2" = MiniMax (available, not the default), then the key (no base_url
    # prompt). The anthropic_compatible + base_url block must land so the first
    # turn can route — the coherence the F-SETUP-1 fix guarantees per provider.
    ok = wizard("2\nsk-minimax-test\n").run
    expect(ok).to be true

    loader = Rubino::Config::Loader.new(home_path: home)
    raw    = YAML.safe_load_file(loader.config_path)
    expect(raw.dig("model", "default")).to eq("MiniMax-M3")
    expect(raw.dig("model", "provider")).to eq("minimax")
    expect(raw.dig("providers", "minimax", "anthropic_compatible")).to be true
    expect(raw.dig("providers", "minimax", "base_url")).to eq("https://api.minimax.io/anthropic")
    expect(raw.dig("providers", "minimax", "api_key")).to eq("${MINIMAX_API_KEY}")

    env = File.read(loader.env_path)
    expect(env).to include("MINIMAX_API_KEY=sk-minimax-test")

    config = Rubino::Config::Configuration.new(raw: loader.load)
    expect(Rubino::LLM::CredentialCheck.usable?(config)).to be true
  end

  it "detects an already-present env key and reuses it instead of forcing a paste" do
    # Smooth path (industry norm): when the chosen provider's env var is already
    # set, the wizard offers to use it; a bare Enter accepts the detected key.
    ENV["OPENAI_API_KEY"] = "sk-from-env"
    begin
      # "1" = OpenAI, then Enter to accept the detected env key.
      ok = wizard("1\n\n").run
      expect(ok).to be true

      loader = Rubino::Config::Loader.new(home_path: home)
      raw    = YAML.safe_load_file(loader.config_path)
      expect(raw.dig("model", "provider")).to eq("openai")
      # The detected key was persisted to .env (durable for future runs).
      expect(File.read(loader.env_path)).to include("OPENAI_API_KEY=sk-from-env")
      expect(output.string).to include("Detected OPENAI_API_KEY")
    ensure
      ENV.delete("OPENAI_API_KEY")
    end
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
  # abandon the wizard. Here it is out of range, then "1" (OpenAI) + a key.
  it "re-prompts on an invalid choice instead of abandoning setup" do
    n = described_class::PROVIDERS.size
    ok = wizard("#{n + 5}\n1\nsk-openai-test\n").run
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

  # H2: a Ctrl-C MID-wizard (after picking a provider, before pasting the key)
  # used to escape as a raw `Interrupt` backtrace out of gets/noecho. It must
  # abort CLEANLY — "Setup cancelled." + exit 130 — and leave NO half-written
  # provider config (re-running setup must work).
  describe "Ctrl-C mid-wizard (H2)" do
    # An input that yields the provider choice on the FIRST `gets`, then raises
    # Interrupt on the next read (the hidden key prompt) — i.e. the user pressed
    # Ctrl-C after choosing a provider, before typing the key.
    def interrupting_input(first)
      calls = 0
      input = double("interrupting-input")
      allow(input).to receive(:gets) do
        calls += 1
        calls == 1 ? first : raise(Interrupt)
      end
      input
    end

    def cancelling_wizard
      described_class.new(ui: ui, input: interrupting_input("1\n"), output: output)
    end

    it "exits 130 with a clean 'Setup cancelled.' and no backtrace" do
      status = nil
      expect do
        cancelling_wizard.run
      rescue SystemExit => e
        status = e.status
      end.not_to raise_error

      expect(status).to eq(130)
      expect(output.string).not_to include(".rb:")
    end

    it "writes NO provider config on abort, so re-running setup works" do
      begin
        cancelling_wizard.run
      rescue SystemExit
        nil
      end

      loader = Rubino::Config::Loader.new(home_path: home)
      # No config.yml was persisted by the wizard (persist! runs only after a
      # non-empty key), and a fresh wizard run after the abort completes.
      ok = wizard("1\nsk-openai-after-abort\n").run
      expect(ok).to be true
      raw = YAML.safe_load_file(loader.config_path)
      expect(raw.dig("model", "provider")).to eq("openai")
    end
  end
end
