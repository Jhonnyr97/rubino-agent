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

    it "hides superseded facts from list by default and includes them with --all (#82)" do
      backend.store(kind: "preference", content: "User prefers tabs over spaces.")
      backend.replace(kind: "preference", old_text: "tabs over spaces",
                      content: "User prefers spaces over tabs.")

      expect(Rubino.ui).to receive(:table) do |rows:, **|
        contents = rows.map { |r| r[2] }.join(" ")
        expect(contents).to include("spaces over tabs")
        expect(contents).not_to include("tabs over spaces")
      end
      described_class.new([], { "limit" => 20 }).list

      expect(Rubino.ui).to receive(:table) do |rows:, **|
        expect(rows.size).to eq(2)
      end
      described_class.new([], { "limit" => 20, "all" => true }).list
    end

    it "marks retired rows in list --all with their retirement date and successor (#161)" do
      old = backend.store(kind: "preference", content: "User prefers tabs over spaces.")
      backend.replace(kind: "preference", old_text: "tabs over spaces",
                      content: "User prefers spaces over tabs.")
      successor_id = backend.find(old[:id])[:superseded_by]

      expect(Rubino.ui).to receive(:table) do |rows:, **|
        retired_row = rows.find { |r| r[0] == old[:id][0..7] }
        live_row    = rows.find { |r| r[2].include?("spaces over tabs") }
        expect(retired_row[2]).to match(/\(retired \d{4}-\d{2}-\d{2} → #{successor_id[0..7]}\)/)
        expect(live_row[2]).not_to include("(retired")
      end
      described_class.new([], { "limit" => 20, "all" => true }).list
    end

    it "show prints the temporal chain of a retired fact (#88)" do
      old = backend.store(kind: "fact", content: "User works at Acme.")
      backend.replace(kind: "fact", old_text: "Acme", content: "User works at Globex.")

      described_class.new.show(old[:id][0..7])

      infos = Rubino.ui.messages.select { |m| m[:level] == :info }.map { |m| m[:message] }.join("\n")
      expect(infos).to match(/Retired: \S+/)
      expect(infos).to match(/Superseded by: \S+/)
    end

    it "show omits the temporal chain for a live fact (#88)" do
      row = backend.store(kind: "fact", content: "User works at Acme.")

      described_class.new.show(row[:id][0..7])

      infos = Rubino.ui.messages.select { |m| m[:level] == :info }.map { |m| m[:message] }.join("\n")
      expect(infos).not_to include("Retired:")
      expect(infos).not_to include("Superseded by:")
    end

    it "deletes (forgets) a fact from the active backend" do
      row = backend.store(kind: "fact", content: "User's deploy port is 7788.")
      expect(backend.count).to eq(1)

      expect(Rubino.ui).to receive(:success).with(/Memory deleted/)
      described_class.new.delete(row[:id][0..7])

      expect(backend.count).to eq(0)
      expect(backend.find(row[:id])).to be_nil
    end

    # P2-H1/H2: a not-found show/delete is a FAILURE on the automation surface —
    # it must raise Thor::Error (exit non-zero, message on stderr), matching
    # SessionCommand, not print to stdout and return 0.
    it "show raises Thor::Error for an unknown id (non-zero exit, stderr)" do
      expect { described_class.new.show("does-not-exist") }
        .to raise_error(Thor::Error, /memory not found: does-not-exist/)
    end

    it "delete raises Thor::Error for an unknown id (non-zero exit, stderr)" do
      expect { described_class.new.delete("does-not-exist") }
        .to raise_error(Thor::Error, /memory not found: does-not-exist/)
      expect(backend.count).to eq(0)
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

    it "refuses an unregistered backend and writes nothing (Thor::Error, non-zero)" do
      expect { command.backend("bogus") }
        .to raise_error(Thor::Error, /Unknown memory backend: bogus/)
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
