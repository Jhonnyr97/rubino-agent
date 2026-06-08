# frozen_string_literal: true

require "tmpdir"

RSpec.describe Rubino::CLI::MemoryCommand do
  subject(:command) { described_class.new }

  before { Rubino.ui = Rubino::UI::Null.new }

  # Regression for #94: the CLI memory subcommands must read/write the SAME
  # active backend the agent loop and the HTTP /v1/memory ops use (the
  # configured sqlite tiny-Zep backend), not the legacy `:memories` table that
  # `Memory::Store` is hardwired to. A fact stored through the active backend
  # must therefore be visible to `memory list`/`show` and removable by
  # `memory delete`.
  describe "active-backend routing (#94)" do
    let(:db_connection) { test_database }
    let(:db) { db_connection.db }
    let(:config) do
      test_configuration(
        "memory" => {
          "enabled" => true, "backend" => "sqlite",
          "user_profile_enabled" => true, "project_context_enabled" => true,
          "memory_char_limit" => 2200, "user_char_limit" => 1375,
          "sqlite" => { "vector" => false }
        }
      )
    end
    let(:backend) { Rubino::Memory::Backends::Sqlite.new(config: config, db: db) }

    before do
      # The CLI resolves its store via Memory::Backends.build (the configured
      # backend) — exactly like the HTTP /v1/memory ops. Pin it to the same
      # sqlite instance the test stores facts through.
      allow(Rubino::Memory::Backends).to receive(:build).and_return(backend)
      # The CLI must NOT touch the legacy store anymore.
      allow(Rubino::Memory::Store).to receive(:new).and_raise("CLI must use the active backend, not Memory::Store")
    end

    it "lists facts stored through the active (sqlite) backend" do
      backend.store(kind: "fact", content: "User's project deploy port is 7788.")

      expect(Rubino.ui).to receive(:table) do |headers:, rows:|
        expect(headers).to include("Content")
        contents = rows.map { |r| r[2] }
        expect(contents).to include(a_string_matching(/deploy port is 7788/))
      end

      described_class.new([], { "limit" => 20 }).list
    end

    it "shows a fact stored through the active backend by id prefix" do
      row = backend.store(kind: "fact", content: "User prefers concise answers.")

      expect(Rubino.ui).to receive(:info).with("User prefers concise answers.")
      allow(Rubino.ui).to receive(:info)
      allow(Rubino.ui).to receive(:separator)

      described_class.new.show(row[:id][0..7])
    end

    it "deletes (forgets) a fact from the active backend" do
      row = backend.store(kind: "fact", content: "User's deploy port is 7788.")
      expect(backend.count).to eq(1)

      expect(Rubino.ui).to receive(:success).with(/Memory deleted/)
      described_class.new.delete(row[:id][0..7])

      expect(backend.count).to eq(0)
      expect(backend.find(row[:id])).to be_nil
    end
  end

  describe "#backend" do
    let(:tmp_config) { File.join(Dir.mktmpdir, "config.yml") }
    let(:writer) { Rubino::Config::Writer.new(config_path: tmp_config) }

    before do
      loader = instance_double(Rubino::Config::Loader, config_path: tmp_config)
      allow(Rubino::Config::Loader).to receive(:new).and_return(loader)
    end

    it "persists memory.backend for a registered backend" do
      command.backend("default")
      expect(writer.get("memory.backend")).to eq("default")
    end

    it "refuses an unregistered backend and writes nothing" do
      expect(Rubino.ui).to receive(:error).with(/Unknown memory backend: bogus/)
      command.backend("bogus")
      expect(writer.get("memory.backend")).to be_nil
    end

    it "shows the active backend and available list when given no name" do
      allow(Rubino).to receive(:configuration).and_return(test_configuration)
      expect(Rubino.ui).to receive(:info).with(/Active backend:/)
      expect(Rubino.ui).to receive(:info).with(/Available:.*default/)
      command.backend
    end
  end
end
