# frozen_string_literal: true

RSpec.describe Rubino::CLI::DoctorCommand do
  subject(:doctor) { described_class.new }

  let(:ui) { Rubino::UI::Null.new }

  before { Rubino.ui = ui }

  describe "#check_migrations" do
    # memory?: true short-circuits the read-only on-disk guard (#68) so these
    # examples keep exercising the migrator logic itself. corrupt?: false so the
    # #359 corruption short-circuit doesn't intercept the healthy-DB paths.
    let(:db) do
      instance_double(Rubino::Database::Connection,
                      memory?: true, corrupt?: false, corruption_error?: false)
    end

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

    # #541 (honesty): a PRESENT key is reported as present-and-unverified, never
    # as "configured" — doctor makes no live auth probe, so a bogus key must not
    # earn a green that implies it was validated. The check still passes (a key
    # IS present), but the copy says "present", "not verified", and names the
    # verify step so the green can't be misread as "works".
    it "reports a present key as 'present — not verified', not 'configured'" do
      with_config("model" => { "default" => "anthropic/claude-3-5-sonnet", "provider" => "auto" })
      ENV["ANTHROPIC_API_KEY"] = "sk-fake-invalid-xyz"

      doctor.send(:check_provider_keys)

      msg = ui.messages.last
      expect(msg).to include(level: :success)
      expect(msg[:message]).to include("present")
      expect(msg[:message]).to match(/not verified/i)
      expect(msg[:message]).not_to match(/\bconfigured\b/)
    end

    # The core finding: a tenant on an openai_compatible provider configures its
    # key under providers.<name>.api_key in config.yml. The old hardcoded ENV
    # allowlist ignored that and warned "No API keys found" on a healthy tenant.
    it "is :ok when an openai_compatible provider carries its key in config" do
      with_config(
        "model" => { "default" => "my-local-model", "provider" => "gateway" },
        "providers" => { "gateway" => { "openai_compatible" => true, "api_key" => "tenant-key" } }
      )

      result = doctor.send(:check_provider_keys)

      expect(result).to eq(name: "provider_keys", status: :ok)
      expect(ui.messages.last[:message]).to include("gateway")
    end

    it "is :ok for an openai_compatible provider falling back to OPENAI_API_KEY" do
      with_config(
        "model" => { "default" => "local", "provider" => "vllm" },
        "providers" => { "vllm" => { "openai_compatible" => true } }
      )
      ENV["OPENAI_API_KEY"] = "sk-openai"

      result = doctor.send(:check_provider_keys)

      expect(result).to eq(name: "provider_keys", status: :ok)
    end

    # #327(c): a missing key for the CONFIGURED provider is a hard ✗ (:fail),
    # not a soft ⚠ — it is REQUIRED for any model call, so an install without it
    # is broken, not merely degraded.
    it "fails naming the configured provider when no credentials resolve" do
      with_config("model" => { "default" => "anthropic/claude-3-5-sonnet", "provider" => "auto" })

      result = doctor.send(:check_provider_keys)

      expect(result).to eq(name: "provider_keys", status: :fail)
      expect(ui.messages.last).to include(level: :error)
      expect(ui.messages.last[:message]).to include("anthropic")
    end

    # Regression: an unrelated ENV key (OpenAI) must NOT mark a tenant
    # configured for a DIFFERENT provider (Anthropic) as healthy. The old
    # allowlist did exactly that.
    it "ignores ENV keys that belong to a different provider" do
      with_config("model" => { "default" => "anthropic/claude-3-5-sonnet", "provider" => "auto" })
      ENV["OPENAI_API_KEY"] = "sk-openai"

      result = doctor.send(:check_provider_keys)

      expect(result[:status]).to eq(:fail)
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
        "model" => { "default" => "MiniMax-M2.7", "provider" => "minimax" },
        "providers" => { "minimax" => { "anthropic_compatible" => true, "api_key" => "mm-key" } }
      )

      result = doctor.send(:check_provider_keys)

      expect(result).to eq(name: "provider_keys", status: :ok)
      expect(ui.messages.last[:message]).to include("minimax")
    end
  end

  # #327(c): doctor must validate the configured model EXISTS, not merely that
  # a non-empty string is present — a typo'd model.default used to pass doctor
  # and only fail at the first model call.
  describe "#check_model_configured (model existence)" do
    def with_config(raw)
      config = Rubino::Config::Configuration.new(raw: raw, home_path: nil)
      allow(Rubino).to receive(:configuration).and_return(config)
    end

    it "is :fail when no model is configured" do
      with_config("model" => { "default" => "" })
      expect(doctor.send(:check_model_configured)).to eq(name: "model", status: :fail)
    end

    it "is :ok for a real registry model id" do
      with_config("model" => { "default" => "gpt-4.1", "provider" => "openai" })
      allow(doctor).to receive(:model_usable?).and_return(true)
      allow(doctor).to receive(:assume_exists_provider?).and_return(false)
      allow(doctor).to receive(:model_in_catalog?).with("gpt-4.1").and_return(true)
      expect(doctor.send(:check_model_configured)).to eq(name: "model", status: :ok)
    end

    it "is :warn for a typo'd model id on a registry provider" do
      with_config("model" => { "default" => "gpt-4o-typooo", "provider" => "openai" })
      allow(doctor).to receive(:model_usable?).and_return(true)
      allow(doctor).to receive(:assume_exists_provider?).and_return(false)
      allow(doctor).to receive(:model_in_catalog?).with("gpt-4o-typooo").and_return(false)

      result = doctor.send(:check_model_configured)

      expect(result).to eq(name: "model", status: :warn)
      expect(ui.messages.last).to include(level: :warning)
    end

    it "stays :ok for an assume-exists / compatible provider (no registry lookup)" do
      with_config(
        "model" => { "default" => "MiniMax-M2.7", "provider" => "minimax" },
        "providers" => { "minimax" => { "anthropic_compatible" => true } }
      )
      allow(doctor).to receive(:model_usable?).and_return(true)
      expect(doctor.send(:check_model_configured)).to eq(name: "model", status: :ok)
    end
  end

  # #546 (pre-setup honesty): before `setup` has run, a never-setup install
  # carries a seeded placeholder `model.default` under an assume-exists provider
  # but NO usable credential. Doctor used to print a green "Model configured: …"
  # there — an all-green line that contradicts the unconfigured state. With no
  # usable credential the model line must be an actionable warning pointing at
  # setup, never a green success. A genuinely configured+usable setup still
  # reports the green success. Consistent with the #541 present-vs-verified fix.
  describe "#check_model_configured (pre-setup honesty, #546)" do
    def with_config(raw)
      config = Rubino::Config::Configuration.new(raw: raw, home_path: nil)
      allow(Rubino).to receive(:configuration).and_return(config)
    end

    it "does NOT print a green 'Model configured' when no usable credential exists" do
      with_config(
        "model" => { "default" => "MiniMax-M2.7", "provider" => "minimax" },
        "providers" => { "minimax" => { "anthropic_compatible" => true } }
      )
      allow(doctor).to receive(:model_usable?).and_return(false)

      result = doctor.send(:check_model_configured)

      expect(result).to eq(name: "model", status: :warn)
      last = ui.messages.last
      expect(last[:level]).to eq(:warning)
      expect(last[:message]).not_to include("Model configured")
    end

    it "surfaces the actionable 'run setup' guidance when no usable credential exists" do
      with_config("model" => { "default" => "gpt-4.1", "provider" => "openai" })
      allow(doctor).to receive(:model_usable?).and_return(false)

      doctor.send(:check_model_configured)

      expect(ui.messages.last[:message]).to include("rubino setup")
      expect(ui.messages.none? { |m| m[:level] == :success }).to be(true)
    end

    it "still reports the green success for a configured+usable setup" do
      with_config(
        "model" => { "default" => "MiniMax-M2.7", "provider" => "minimax" },
        "providers" => { "minimax" => { "anthropic_compatible" => true, "api_key" => "mm-key" } }
      )

      result = doctor.send(:check_model_configured)

      expect(result).to eq(name: "model", status: :ok)
      expect(ui.messages.last[:level]).to eq(:success)
      expect(ui.messages.last[:message]).to include("Model configured")
    end
  end

  # #143: a healthy CLI install must report a clean/green verdict. The
  # server-only encryption key is NOT counted against the headline score, so a
  # default install with no RUBINO_ENCRYPTION_KEY still reports all-green.
  describe "#execute headline verdict" do
    around do |example|
      saved = ENV.fetch("RUBINO_ENCRYPTION_KEY", nil)
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
      expect(verdict[:level]).to eq(:info) # informational note about optional check
      success = ui.messages.find { |m| m[:level] == :success && m[:message].to_s.include?("checks passed") }
      expect(success[:message]).to include("All 6 checks passed!")
      # The summary must NOT contain a "6/7" warning verdict.
      expect(ui.messages.none? { |m| m[:level] == :warning && m[:message].to_s.match?(%r{\d/\d}) }).to be(true)
    end

    # #557: a failed required check is a genuine FAILURE — the headline verdict
    # must render the red ✗ (level :error), not the soft yellow ⚠ (level
    # :warning) that understated an all-broken install as a mild caution.
    it "renders the failure verdict as ✗ (error) and exits non-zero when a REQUIRED check fails (#67/#557)" do
      allow(doctor).to receive(:check_model_configured).and_return(name: "model", status: :fail)

      expect { doctor.execute }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }

      verdict = ui.messages.find { |m| m[:message].to_s.include?("required checks passed") }
      expect(verdict[:level]).to eq(:error)
      expect(verdict[:message]).to include("5/6 required checks passed")
      # The verdict must NOT be a soft warning anymore.
      expect(ui.messages.none? { |m| m[:level] == :warning && m[:message].to_s.match?(%r{\d/\d}) }).to be(true)
    end

    # #67: scripts/CI gate on doctor, so the all-green path must stay exit 0
    # (no exit call at all) and any non-:ok required check must exit 1.
    it "does not exit when every required check passes" do
      expect { doctor.execute }.not_to raise_error
    end

    it "exits non-zero when a required check only warns (not fully passing)" do
      allow(doctor).to receive(:check_provider_keys).and_return(name: "provider_keys", status: :warn)

      expect { doctor.execute }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  end

  # #68: doctor is a READ-ONLY diagnosis. On a never-setup home it must not
  # create the home directory or the database file (SQLite lazily creates the
  # file on the first connection — and the old code then reported that empty,
  # unmigrated database as "accessible"). It reports "run 'rubino setup'" and
  # exits non-zero (#67) instead.
  describe "#execute on a never-setup home" do
    around do |example|
      Dir.mktmpdir("rubino_doctor") do |dir|
        orig = ENV.fetch("RUBINO_HOME", nil)
        ENV["RUBINO_HOME"] = File.join(dir, "never-setup-home")
        Rubino.reset!
        example.run
      ensure
        orig.nil? ? ENV.delete("RUBINO_HOME") : ENV["RUBINO_HOME"] = orig
        Rubino.reset!
      end
    end

    it "creates nothing, points at setup, and exits non-zero" do
      home = ENV.fetch("RUBINO_HOME")

      expect { doctor.execute }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }

      expect(File).not_to exist(home)
      errors = ui.messages.select { |m| m[:level] == :error }.map { |m| m[:message] }
      expect(errors.join("\n")).to include("rubino setup")
      expect(errors.join("\n")).to include("database not initialized")
    end
  end

  # F4: the OAuth-token encryption key is only needed by the API/OAuth server.
  # For a CLI-only user a missing key is a scoped :warn, not a red :fail that
  # makes a healthy install look broken. A key that is SET but malformed is
  # still a real :fail.
  describe "#check_encryption_key" do
    around do |example|
      saved = ENV.fetch("RUBINO_ENCRYPTION_KEY", nil)
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

  # #259: a structurally corrupt config (a scalar written over the `model`
  # section by an old `config set model foo`) must surface as a graceful
  # "config corrupt" diagnostic and a non-zero exit — never a raw
  # `String does not have #dig` TypeError backtrace.
  describe "corrupt config (#259)" do
    around do |example|
      Dir.mktmpdir("rubino_doctor_corrupt") do |dir|
        orig = ENV.fetch("RUBINO_HOME", nil)
        ENV["RUBINO_HOME"] = dir
        # The exact shape the old bug produced: a scalar over the model section.
        File.write(File.join(dir, "config.yml"), { "model" => "foo" }.to_yaml)
        Rubino.reset!
        example.run
      ensure
        orig.nil? ? ENV.delete("RUBINO_HOME") : ENV["RUBINO_HOME"] = orig
        Rubino.reset!
      end
    end

    it "reports a corrupt-config diagnostic from check_config (no raise)" do
      result = nil
      expect { result = doctor.send(:check_config) }.not_to raise_error

      expect(result).to eq(name: "config", status: :fail)
      expect(ui.messages.last[:level]).to eq(:error)
      expect(ui.messages.last[:message]).to include("config corrupt")
    end

    it "fails the provider/model checks gracefully instead of a TypeError" do
      expect { doctor.send(:check_provider_keys) }.not_to raise_error
      expect(doctor.send(:check_provider_keys)[:status]).to eq(:fail)

      expect { doctor.send(:check_model_configured) }.not_to raise_error
      expect(doctor.send(:check_model_configured)[:status]).to eq(:fail)
    end

    it "execute exits non-zero without a TypeError backtrace" do
      expect { doctor.execute }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }

      errors = ui.messages.select { |m| m[:level] == :error }.map { |m| m[:message] }
      expect(errors.join("\n")).to include("config corrupt")
    end
  end

  # #359: a corrupt-but-present DB used to leak the raw SQLite3::CorruptException
  # class + a stray `PRAGMA journal_mode=WAL` fragment into doctor's output
  # (check_migrations connected, ran the PRAGMA, and printed the wrapped
  # exception message). The DB checks must report a clean "corrupt … run setup"
  # diagnostic with NONE of that internal noise.
  describe "corrupt-database output hygiene (#359)" do
    let(:corrupt_dir)  { Dir.mktmpdir("ra-doctor-corrupt") }
    let(:corrupt_path) { File.join(corrupt_dir, "rubino.sqlite3") }

    after { FileUtils.remove_entry(corrupt_dir) }

    before do
      seed = Rubino::Database::Connection.new(corrupt_path)
      seed.db.run("CREATE TABLE t (a integer, b text)")
      300.times { |i| seed.db.run("INSERT INTO t VALUES (#{i}, '#{"x" * 200}')") }
      seed.close
      File.truncate(corrupt_path, 20_000)
      allow(Rubino).to receive(:database)
        .and_return(Rubino::Database::Connection.new(corrupt_path))
    end

    def all_messages
      ui.messages.map { |m| m[:message].to_s }
    end

    it "check_database reports a clean corrupt diagnostic (no raw class / PRAGMA leak)" do
      result = doctor.send(:check_database)

      expect(result).to eq(name: "database", status: :fail)
      last = ui.messages.last
      expect(last[:level]).to eq(:error)
      expect(last[:message]).to match(/corrupt/i)
      expect(last[:message]).to include("rubino setup")
      expect(all_messages.join("\n")).not_to include("SQLite3::CorruptException")
      expect(all_messages.join("\n")).not_to include("journal_mode")
    end

    it "check_migrations degrades cleanly without leaking the exception or PRAGMA" do
      result = doctor.send(:check_migrations)

      expect(result).to eq(name: "migrations", status: :fail)
      expect(ui.messages.last[:level]).to eq(:error)
      expect(all_messages.join("\n")).not_to include("SQLite3::CorruptException")
      expect(all_messages.join("\n")).not_to include("journal_mode")
    end
  end

  describe "#check_document_converters (#6, non-scoring)" do
    it "reports the always-available pure-ruby formats as success" do
      doctor.send(:check_document_converters)
      successes = ui.messages.select { |m| m[:level] == :success }.map { |m| m[:message].to_s }
      expect(successes).to include(a_string_including("plain/code supported"))
      expect(successes).to include(a_string_including("csv supported"))
      expect(successes).to include(a_string_including("html supported"))
    end

    it "warns (never fails) for a format whose optional gem is absent" do
      allow(Rubino::Documents::Registry).to receive(:capabilities)
        .and_return("pdf" => false)
      doctor.send(:check_document_converters)
      warning = ui.messages.find { |m| m[:level] == :warning }
      expect(warning[:message]).to include("pdf not available")
      expect(ui.messages.none? { |m| m[:level] == :error }).to be(true)
    end
  end

  # F8: when `tools.web` is on, doctor reports WHICH search backend a query
  # would use (Tavily / SearXNG / keyless DDG) and whether it looks usable, so a
  # user knows websearch will actually work. It is informational — never scored,
  # never a :fail — like the MCP / doc-converter sections.
  describe "#check_websearch_backend (F8)" do
    around do |example|
      saved = ENV.to_hash.slice("TAVILY_API_KEY", "SEARXNG_URL")
      ENV.delete("TAVILY_API_KEY")
      ENV.delete("SEARXNG_URL")
      example.run
    ensure
      ENV.delete("TAVILY_API_KEY")
      ENV.delete("SEARXNG_URL")
      saved.each { |k, v| ENV[k] = v }
    end

    it "reports Tavily when TAVILY_API_KEY is set" do
      ENV["TAVILY_API_KEY"] = "tvly-xxx"
      doctor.send(:check_websearch_backend)
      msg = ui.messages.find { |m| m[:level] == :success }
      expect(msg[:message]).to include("Tavily")
      expect(ui.messages.none? { |m| m[:level] == :error }).to be(true)
    end

    it "reports SearXNG when only SEARXNG_URL is set" do
      ENV["SEARXNG_URL"] = "https://searx.example/search"
      doctor.send(:check_websearch_backend)
      msg = ui.messages.find { |m| m[:level] == :success }
      expect(msg[:message]).to include("SearXNG")
    end

    it "reports keyless DuckDuckGo when reachable and no key is set" do
      allow(doctor).to receive(:ddg_resolvable?).and_return(true)
      doctor.send(:check_websearch_backend)
      msg = ui.messages.find { |m| m[:level] == :success }
      expect(msg[:message]).to include("DuckDuckGo")
    end

    it "warns (never fails) when no backend looks usable" do
      allow(doctor).to receive(:ddg_resolvable?).and_return(false)
      doctor.send(:check_websearch_backend)
      warning = ui.messages.find { |m| m[:level] == :warning }
      expect(warning[:message]).to include("Web search may not work")
      expect(ui.messages.none? { |m| m[:level] == :error }).to be(true)
    end
  end
end
