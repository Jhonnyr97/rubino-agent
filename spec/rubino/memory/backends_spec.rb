# frozen_string_literal: true

RSpec.describe Rubino::Memory::Backends do
  let(:db_connection) { test_database }
  let(:config) { test_configuration }
  let(:store) { Rubino::Memory::Store.new(db: db_connection.db, config: config) }

  describe ".build" do
    it "builds the default (sqlite) backend when memory.backend is unset" do
      cfg = test_configuration("memory" => { "enabled" => true })
      backend = described_class.build(config: cfg)
      expect(backend).to be_a(Rubino::Memory::Backends::Sqlite)
    end

    it "REJECTS an explicitly-set unknown backend name with a clear, actionable error" do
      cfg = test_configuration("memory" => { "enabled" => true, "backend" => "does-not-exist" })
      expect { described_class.build(config: cfg) }
        .to raise_error(Rubino::Error, /unknown memory backend "does-not-exist".*set memory\.backend to one of/m)
    end

    it "lists the registered backends in the rejection so the user can fix the typo" do
      cfg = test_configuration("memory" => { "enabled" => true, "backend" => "typo" })
      expect { described_class.build(config: cfg) }
        .to raise_error(Rubino::Error) { |e| expect(e.message).to include(*described_class.names) }
    end

    it "still falls back to the default (sqlite) backend when memory.backend is BLANK (not a typo)" do
      cfg = test_configuration("memory" => { "enabled" => true, "backend" => "  " })
      expect(described_class.build(config: cfg)).to be_a(Rubino::Memory::Backends::Sqlite)
    end
  end

  describe "shipped default" do
    it "ships memory.backend => sqlite in Config::Defaults" do
      expect(Rubino::Config::Defaults.dig("memory", "backend")).to eq("sqlite")
    end

    it "a fresh config with no explicit memory overrides resolves to the sqlite backend" do
      # Full shipped defaults: the memory hash is intact and carries
      # backend => sqlite, so a brand-new user (no memory config) gets sqlite.
      cfg = test_configuration
      name = cfg.dig("memory", "backend").to_s
      expect(name).to eq("sqlite")
      expect(described_class.fetch(name)).to eq(Rubino::Memory::Backends::Sqlite)
    end

    it "the sqlite backend boots and round-trips against a fresh migrated db" do
      cfg = test_configuration
      backend = Rubino::Memory::Backends::Sqlite.new(config: cfg, db: db_connection.db)
      expect(backend.available?).to be(true)
      expect { backend.store(kind: "fact", content: "user uses zsh") }.not_to raise_error
    end
  end

  describe ".registered? / .names" do
    it "knows the sqlite backend is registered" do
      expect(described_class.registered?("sqlite")).to be(true)
      expect(described_class.names).to include("sqlite")
    end

    it "reports an unknown name as not registered" do
      expect(described_class.registered?("nope")).to be(false)
    end
  end
end
