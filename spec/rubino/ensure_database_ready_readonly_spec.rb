# frozen_string_literal: true

require "tmpdir"

# F14: a read-only ~/.rubino used to surface the MISLEADING "rubino isn't set up
# yet — run `rubino setup`" because ensure_database_ready! masked the write
# failure as a plain `false`. It must instead raise a ConfigurationError with
# the ACCURATE diagnosis ("not writable") — which the single CLI chokepoint
# turns into a clean one-line message (doctor already diagnoses it correctly).
RSpec.describe Rubino, ".ensure_database_ready! on a read-only home (F14)" do
  let(:home) { Dir.mktmpdir("ra-ro") }

  around do |ex|
    prev = ENV.fetch("RUBINO_HOME", nil)
    ENV["RUBINO_HOME"] = home
    described_class.reset!
    ex.run
  ensure
    FileUtils.chmod_R(0o755, home) # so cleanup can remove it
    ENV["RUBINO_HOME"] = prev
    described_class.reset!
    FileUtils.remove_entry(home)
  end

  it "raises an ACCURATE 'not writable' ConfigurationError, not a 'false'" do
    # Materialize a healthy, migrated home first.
    expect(described_class.ensure_database_ready!).to be(true)
    described_class.reset!

    # Now make the home read-only — a read-only mount / foreign-owned dir.
    FileUtils.chmod_R("a-w", home)

    expect { described_class.ensure_database_ready! }
      .to raise_error(Rubino::ConfigurationError, /not writable/i)
  end

  it "returns true on a normal writable home (no false positive)" do
    expect(described_class.ensure_database_ready!).to be(true)
  end

  # #Y2A — a read-only DB UNDER the OS write-jail (a nested rubino launched from
  # inside the agent's jailed shell) gets the attributable write-jail hint
  # appended, not just an opaque "not writable". Outside the jail (or jail off)
  # the message is unchanged.
  describe "write-jail attribution (#Y2A)" do
    it "appends the write-jail hint when the home is outside an enforcing jail" do
      allow(Rubino::Security::Sandbox).to receive_messages(enforcing?: true, writable?: false)

      expect(described_class.write_jail_db_hint)
        .to include("outside the workspace write-jail", "nested rubino", "tools.sandbox")
    end

    it "is empty when the jail is not enforcing" do
      allow(Rubino::Security::Sandbox).to receive(:enforcing?).and_return(false)
      expect(described_class.write_jail_db_hint).to eq("")
    end

    it "is empty when the home IS writable under the jail (genuine read-only mount)" do
      allow(Rubino::Security::Sandbox).to receive_messages(enforcing?: true, writable?: true)
      expect(described_class.write_jail_db_hint).to eq("")
    end

    it "surfaces the hint inside the full not-writable ConfigurationError" do
      expect(described_class.ensure_database_ready!).to be(true)
      described_class.reset!
      FileUtils.chmod_R("a-w", home)

      allow(Rubino::Security::Sandbox).to receive_messages(enforcing?: true, writable?: false)

      expect { described_class.ensure_database_ready! }
        .to raise_error(Rubino::ConfigurationError,
                        /not writable.*outside the workspace write-jail/m)
    end
  end
end
