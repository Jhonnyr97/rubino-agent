# frozen_string_literal: true

# R3C-1 / STRM-R2-1 — the background shell drain scrubs its ring buffer at the
# capture seam, mirroring the FOREGROUND shell (ShellTool drains through
# Util::Output.scrub_utf8). Without this a binary / latin-1 background process
# leaves invalid UTF-8 (and NUL) in the buffer; when `shell_output` returns it,
# JSON.generate (the LLM request) and the SQLite driver raise and the tool row
# never persists — the model loses the record on --resume.
RSpec.describe Rubino::Tools::ShellRegistry do
  subject(:registry) { described_class.new }

  it "scrubs invalid UTF-8 and NUL out of the background buffer" do
    # A background process that emits raw binary: invalid UTF-8 byte (0xE9 alone)
    # plus a NUL — both SQLite/JSON-fatal if they survive into read_all.
    entry = registry.spawn(command: %(printf 'a\\xe9b\\x00c\\n'), cwd: Dir.pwd)
    entry.wait_thr.join
    sleep 0.1 # let the reader thread drain EOF

    buffer = registry.read_all(entry)
    expect(buffer).to be_valid_encoding
    expect(buffer).not_to include("\x00")
    # The legitimate text around the stripped bytes survives.
    expect(buffer).to include("a").and include("b").and include("c")
  ensure
    registry.remove(entry.id) if defined?(entry) && entry
  end
end
