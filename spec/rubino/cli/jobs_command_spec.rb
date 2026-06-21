# frozen_string_literal: true

require "tmpdir"

# #560: every `jobs` verb that touches the queue table must guard a
# present-but-unusable / un-initialized DB at the command boundary. Before this,
# `jobs process` / `jobs worker` had NO guard (only `jobs list` did), so on a
# brand-new or un-migratable RUBINO_HOME they hit the `jobs` table directly and
# dumped a raw `SQLite3::SQLException: no such table: jobs` backtrace + the SQL
# statement to the user. They must instead surface a clean, actionable
# Thor::Error (Thor prints it to stderr and exits non-zero, no backtrace) and
# NEVER leak the SQLite class / SQL / a stack trace.
RSpec.describe Rubino::CLI::JobsCommand do
  before { Rubino.ui = Rubino::UI::Null.new }

  # The chokepoint guard returns false when the schema can't be initialized
  # (a genuinely un-set-up install where migrate! failed) — every verb must then
  # raise the clean "run setup" diagnostic, not crash on the missing table.
  describe "un-initialized database guard (#560)" do
    before do
      allow(Rubino).to receive_messages(database_repair_message: nil,
                                        ensure_database_ready!: false)
    end

    %i[list process worker].each do |verb|
      it "##{verb} raises a clean 'run setup' Thor::Error with no SQL/backtrace" do
        cmd = described_class.new([], { "limit" => 10 })
        expect { cmd.public_send(verb) }
          .to raise_error(Thor::Error) { |e|
            expect(e.message).to match(/not initialized.*rubino setup/m)
            expect(e.message).not_to match(/SQLite3|no such table|SELECT|INSERT/i)
            expect(e.message).not_to include(".rb:")
          }
      end
    end
  end

  # A PRESENT-but-corrupt image is its own diagnosis: the shared repair message
  # points at recovery, and again no verb leaks the raw sqlite backtrace.
  describe "corrupt-database guard (#560)" do
    let(:corrupt_dir)  { Dir.mktmpdir("ra-jobs-corrupt") }
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

    %i[list process worker].each do |verb|
      it "##{verb} raises a clean corrupt-DB Thor::Error (no raw sqlite backtrace)" do
        cmd = described_class.new([], { "limit" => 10 })
        expect { cmd.public_send(verb) }
          .to raise_error(Thor::Error) { |e|
            expect(e.message).to match(/corrupt/i)
            expect(e.message).not_to match(/no such table|SELECT|INSERT/i)
          }
      end
    end
  end
end
