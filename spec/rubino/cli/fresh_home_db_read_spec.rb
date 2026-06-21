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
    # The empty state is now actionable (#559): it tells the user where memories
    # come from instead of a bare "No memories found." dead-end.
    expect(info_messages.join("\n")).to match(/No memories yet.*rubino chat/m)
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
    # Actionable empty state (#559): how jobs get here, not a bare dead-end.
    expect(info_messages.join("\n")).to match(/No jobs yet.*rubino chat/m)
  end

  # #560: `jobs process`/`worker` previously skipped the fresh-home guard and hit
  # the `jobs` table directly, dumping a raw `SQLite3::SQLException: no such
  # table: jobs` backtrace. They must now share the same guard `jobs list` uses:
  # migrate the brand-new home on first access, then run cleanly (no SQL leak).
  it "`jobs process` initializes the schema instead of leaking a no-such-table backtrace" do
    expect { Rubino::CLI::JobsCommand.new([], { "limit" => 10 }).process }.not_to raise_error
    # Schema initialized on first access ⇒ the success line printed, no SQL leak.
    all = Rubino.ui.messages.map { |m| m[:message].to_s }.join("\n")
    expect(all).not_to match(/SQLite3|no such table/i)
  end

  # NOTE: the old "raced migration left a duplicate schema_info row" context was
  # removed with the migrator squash. That post-hoc recovery path
  # (database_repair_message's duplicate-row branch + Migrator#repair!) only
  # existed to heal an ALREADY-corrupt DB; the single idempotent baseline applied
  # under the flock + the side-effect-free up_to_date? fast path PREVENTS the
  # duplicate-schema_info race from forming in the first place, so there is no
  # such state left to message about. The #35 fresh-home empty-state behaviour
  # above is unchanged.
end
