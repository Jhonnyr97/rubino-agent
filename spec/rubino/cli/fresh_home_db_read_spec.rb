# frozen_string_literal: true

require "tmpdir"

# Regression for #35: on a brand-new RUBINO_HOME — before `setup`/`chat` has
# migrated the DB — the read CLIs (`memory list`, `sessions list/show/delete/
# compact`, `jobs list`) used to crash with a raw
# `SQLite3::SQLException: no such table` backtrace and exit 1. They must instead
# initialize the schema on first access and render the normal EMPTY STATE,
# exiting 0 (no exception escapes the command).
#
# The DB here is a REAL on-disk SQLite file in an unmigrated tmp home (NOT the
# in-memory `test_database`, which is pre-migrated) so the missing-table path is
# genuinely exercised. A raised exception would make Thor exit 1, so "no raise"
# is the exit-0 assertion.
RSpec.describe "Fresh-home DB read commands (#35)" do
  let(:home) { Dir.mktmpdir("rubino-fresh-home") }
  let(:db_path) { File.join(home, "rubino.sqlite3") }
  let(:config) do
    test_configuration("database" => { "path" => db_path })
  end

  before do
    Rubino.ui = Rubino::UI::Null.new
    allow(Rubino).to receive(:configuration).and_return(config)
    allow(Rubino).to receive(:home_path).and_return(home)
    # Brand-new home: the file does not exist and no schema has been created.
    expect(File.exist?(db_path)).to be(false)
  end

  after { FileUtils.rm_rf(home) }

  def info_messages
    Rubino.ui.messages.select { |m| m[:level] == :info }.map { |m| m[:message].to_s }
  end

  it "`memory list` shows the empty state without a no-such-table crash" do
    expect { Rubino::CLI::MemoryCommand.new([], { "limit" => 20 }).list }.not_to raise_error
    expect(info_messages.join("\n")).to include("No memories found")
  end

  it "`sessions list` shows the empty state without a no-such-table crash" do
    expect { Rubino::CLI::SessionCommand.new([], { "limit" => 20 }).list }.not_to raise_error
    expect(info_messages.join("\n")).to include("No sessions found")
  end

  it "`sessions show` reports not-found (not a no-such-table crash)" do
    # ONE error, in one style (#20): the Thor::Error message (which Thor
    # prints to stderr) carries the id; no duplicate styled ui.error line.
    expect { Rubino::CLI::SessionCommand.new.show("deadbeef") }
      .to raise_error(Thor::Error, /session not found: deadbeef/)
    errors = Rubino.ui.messages.select { |m| m[:level] == :error }.map { |m| m[:message].to_s }
    expect(errors).to be_empty
  end

  it "`jobs list` shows the empty state without a no-such-table crash" do
    expect { Rubino::CLI::JobsCommand.new([], { "limit" => 20 }).list }.not_to raise_error
    expect(info_messages.join("\n")).to include("No jobs found")
  end

  # A concurrent first-boot migration race (#race) can leave the DB with a
  # DUPLICATE schema_info version row and NO user tables. Hitting `sessions
  # list` on that state used to hard-crash with a raw
  # `Sequel::DatabaseError: no such table: sessions` backtrace (violating the
  # #333/#359 "no backtrace escapes" hardening). The read CLIs must instead
  # raise a clean Thor::Error pointing at the repair path, never a backtrace.
  context "when a raced migration left a duplicate schema_info row (#race)" do
    # The base #35 examples run against :memory: (test_configuration forces it),
    # but this case needs a REAL on-disk file so the duplicate-schema_info state
    # actually persists and the read path hits it. Point the config at db_path.
    let(:config) do
      raw = Rubino::Config::Defaults.to_hash
      raw["database"] = { "path" => db_path }
      raw["paths"] = { "home" => home, "memory" => "#{home}/memories", "logs" => "#{home}/logs" }
      Rubino::Config::Configuration.new(raw: raw, home_path: home)
    end

    before do
      db = Sequel.sqlite(db_path)
      db.create_table?(:schema_info) { Integer :version, default: 0, null: false }
      db[:schema_info].multi_insert([{ version: 0 }, { version: 0 }])
      db.disconnect
      Rubino.reset_database!
    end

    it "`sessions list` raises a clean repair error, not a raw DB backtrace" do
      expect { Rubino::CLI::SessionCommand.new([], { "limit" => 20 }).list }
        .to raise_error(Thor::Error) { |e|
          expect(e.message).to include("needs repair").and include("rubino setup")
          expect(e.message).not_to include("no such table")
          expect(e).not_to be_a(Sequel::DatabaseError)
        }
    end

    it "`memory list` raises a clean repair error, not a raw DB backtrace" do
      expect { Rubino::CLI::MemoryCommand.new([], { "limit" => 20 }).list }
        .to raise_error(Thor::Error, /needs repair/)
    end
  end
end
