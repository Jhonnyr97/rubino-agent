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
end
