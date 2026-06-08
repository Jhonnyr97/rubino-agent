# frozen_string_literal: true

RSpec.describe Rubino::CLI::DoctorCommand do
  let(:ui) { Rubino::UI::Null.new }

  subject(:doctor) { described_class.new }

  before { Rubino.ui = ui }

  describe "#check_migrations" do
    let(:db) { instance_double(Rubino::Database::Connection) }

    before { allow(Rubino).to receive(:database).and_return(db) }

    def migrator_double(pending:)
      instance_double(Rubino::Database::Migrator).tap do |m|
        allow(Rubino::Database::Migrator).to receive(:new).with(db).and_return(m)
        allow(m).to receive(:pending?).and_return(pending)
      end
    end

    it "reports :ok when no migrations are pending" do
      migrator_double(pending: false)

      result = doctor.send(:check_migrations)

      expect(result).to eq(name: "migrations", status: :ok)
      expect(ui.messages.last).to include(level: :success)
    end

    it "reports :warn when migrations are pending" do
      migrator_double(pending: true)

      result = doctor.send(:check_migrations)

      expect(result).to eq(name: "migrations", status: :warn)
      expect(ui.messages.last).to include(level: :warning)
    end

    # Regression: the old rescue mapped ANY error (including a real DB failure)
    # to success("Migrations up to date"), so an unreachable DB reported healthy.
    # A raised error must now surface as :fail.
    it "reports :fail when the migration check raises" do
      m = instance_double(Rubino::Database::Migrator)
      allow(Rubino::Database::Migrator).to receive(:new).with(db).and_return(m)
      allow(m).to receive(:pending?).and_raise(Sequel::DatabaseError, "no such table")

      result = doctor.send(:check_migrations)

      expect(result).to eq(name: "migrations", status: :fail)
      expect(ui.messages.last).to include(level: :error)
    end
  end

  describe "#check_provider_keys" do
    def with_config(raw)
      config = Rubino::Config::Configuration.new(raw: raw, home_path: nil)
      allow(Rubino).to receive(:configuration).and_return(config)
    end

    around do |example|
      saved = ENV.to_hash.slice(
        "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY",
        "GOOGLE_API_KEY", "BEDROCK_API_KEY"
      )
      %w[OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GOOGLE_API_KEY BEDROCK_API_KEY].each do |k|
        ENV.delete(k)
      end
      example.run
    ensure
      %w[OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GOOGLE_API_KEY BEDROCK_API_KEY].each do |k|
        ENV.delete(k)
      end
      saved.each { |k, v| ENV[k] = v }
    end

    it "is :ok when the configured provider's native ENV key is set" do
      with_config("model" => { "default" => "anthropic/claude-3-5-sonnet", "provider" => "auto" })
      ENV["ANTHROPIC_API_KEY"] = "sk-ant-xxx"

      result = doctor.send(:check_provider_keys)

      expect(result).to eq(name: "provider_keys", status: :ok)
    end

    # The core finding: a tenant on an openai_compatible provider configures its
    # key under providers.<name>.api_key in config.yml. The old hardcoded ENV
    # allowlist ignored that and warned "No API keys found" on a healthy tenant.
    it "is :ok when an openai_compatible provider carries its key in config" do
      with_config(
        "model"     => { "default" => "my-local-model", "provider" => "rubino-ui" },
        "providers" => { "rubino-ui" => { "openai_compatible" => true, "api_key" => "tenant-key" } }
      )

      result = doctor.send(:check_provider_keys)

      expect(result).to eq(name: "provider_keys", status: :ok)
      expect(ui.messages.last[:message]).to include("rubino-ui")
    end

    it "is :ok for an openai_compatible provider falling back to OPENAI_API_KEY" do
      with_config(
        "model"     => { "default" => "local", "provider" => "vllm" },
        "providers" => { "vllm" => { "openai_compatible" => true } }
      )
      ENV["OPENAI_API_KEY"] = "sk-openai"

      result = doctor.send(:check_provider_keys)

      expect(result).to eq(name: "provider_keys", status: :ok)
    end

    it "warns naming the configured provider when no credentials resolve" do
      with_config("model" => { "default" => "anthropic/claude-3-5-sonnet", "provider" => "auto" })

      result = doctor.send(:check_provider_keys)

      expect(result).to eq(name: "provider_keys", status: :warn)
      expect(ui.messages.last).to include(level: :warning)
      expect(ui.messages.last[:message]).to include("anthropic")
    end

    # Regression: an unrelated ENV key (OpenAI) must NOT mark a tenant
    # configured for a DIFFERENT provider (Anthropic) as healthy. The old
    # allowlist did exactly that.
    it "ignores ENV keys that belong to a different provider" do
      with_config("model" => { "default" => "anthropic/claude-3-5-sonnet", "provider" => "auto" })
      ENV["OPENAI_API_KEY"] = "sk-openai"

      result = doctor.send(:check_provider_keys)

      expect(result[:status]).to eq(:warn)
    end

    it "is :ok for the fake provider without any credentials" do
      with_config("model" => { "default" => "fake-model", "provider" => "auto" })

      result = doctor.send(:check_provider_keys)

      expect(result).to eq(name: "provider_keys", status: :ok)
    end

    # F5: a MiniMax tenant configures an anthropic_compatible provider with its
    # key under providers.minimax.api_key. Doctor must validate THAT provider's
    # credential, not warn "no credentials for openai".
    it "is :ok for an anthropic_compatible provider carrying its key in config (MiniMax)" do
      with_config(
        "model"     => { "default" => "MiniMax-M2.7", "provider" => "minimax" },
        "providers" => { "minimax" => { "anthropic_compatible" => true, "api_key" => "mm-key" } }
      )

      result = doctor.send(:check_provider_keys)

      expect(result).to eq(name: "provider_keys", status: :ok)
      expect(ui.messages.last[:message]).to include("minimax")
    end
  end

  # #143: a healthy CLI install must report a clean/green verdict. The
  # server-only encryption key is NOT counted against the headline score, so a
  # default install with no RUBINO_ENCRYPTION_KEY still reports all-green.
  describe "#execute headline verdict" do
    around do |example|
      saved = ENV["RUBINO_ENCRYPTION_KEY"]
      ENV.delete("RUBINO_ENCRYPTION_KEY")
      example.run
    ensure
      saved.nil? ? ENV.delete("RUBINO_ENCRYPTION_KEY") : ENV["RUBINO_ENCRYPTION_KEY"] = saved
    end

    before do
      # All required checks green; encryption key intentionally absent.
      allow(doctor).to receive(:check_config).and_return(name: "config", status: :ok)
      allow(doctor).to receive(:check_database).and_return(name: "database", status: :ok)
      allow(doctor).to receive(:check_migrations).and_return(name: "migrations", status: :ok)
      allow(doctor).to receive(:check_directories).and_return(name: "directories", status: :ok)
      allow(doctor).to receive(:check_provider_keys).and_return(name: "provider_keys", status: :ok)
      allow(doctor).to receive(:check_model_configured).and_return(name: "model", status: :ok)
    end

    it "reports all-green when every REQUIRED check passes (encryption key missing)" do
      doctor.execute

      verdict = ui.messages.last
      expect(verdict[:level]).to eq(:info)  # informational note about optional check
      success = ui.messages.find { |m| m[:level] == :success }
      expect(success[:message]).to include("All 6 checks passed!")
      # The summary must NOT contain a "6/7" warning verdict.
      expect(ui.messages.none? { |m| m[:level] == :warning && m[:message].to_s.match?(%r{\d/\d}) }).to be(true)
    end

    it "warns only when a REQUIRED check fails" do
      allow(doctor).to receive(:check_model_configured).and_return(name: "model", status: :fail)

      doctor.execute

      warning = ui.messages.find { |m| m[:level] == :warning && m[:message].to_s.include?("required checks passed") }
      expect(warning[:message]).to include("5/6 required checks passed")
    end
  end

  # F4: the OAuth-token encryption key is only needed by the API/OAuth server.
  # For a CLI-only user a missing key is a scoped :warn, not a red :fail that
  # makes a healthy install look broken. A key that is SET but malformed is
  # still a real :fail.
  describe "#check_encryption_key" do
    around do |example|
      saved = ENV["RUBINO_ENCRYPTION_KEY"]
      ENV.delete("RUBINO_ENCRYPTION_KEY")
      example.run
    ensure
      saved.nil? ? ENV.delete("RUBINO_ENCRYPTION_KEY") : ENV["RUBINO_ENCRYPTION_KEY"] = saved
    end

    it "warns (not fails) when the key is missing — CLI-only is fine" do
      result = doctor.send(:check_encryption_key)

      expect(result).to eq(name: "encryption_key", status: :warn)
      expect(ui.messages.last).to include(level: :warning)
    end

    it "fails when the key is present but malformed" do
      ENV["RUBINO_ENCRYPTION_KEY"] = "not-valid-base64-or-too-short"

      result = doctor.send(:check_encryption_key)

      expect(result[:status]).to eq(:fail)
      expect(ui.messages.last).to include(level: :error)
    end
  end
end
