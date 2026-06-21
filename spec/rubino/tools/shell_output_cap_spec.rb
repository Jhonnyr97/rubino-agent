# frozen_string_literal: true

# Issue #539 — the foreground shell tool used to drain a subprocess pipe with
# `rd.each_line` into an UNCAPPED in-memory buffer. An unbounded producer that
# emits without a newline (`cat /dev/zero`, `yes | tr -d '\n'`) accumulated the
# ENTIRE stream into one String — RSS 15MB → 1.36GB in ~1s, then OOM/crash —
# and `cat` is auto-allowed, so it ran headless with no prompt and no --yolo.
#
# The fix caps the RETAINED buffer at the read loop (bounded head+tail, charged
# against bytes actually READ so even output that scrubs to empty — pure NUL —
# is capped) AND KILLS the producer the instant the cap is hit (TERM→KILL, like
# the timeout path), so RAM stays bounded no matter how much the process emits.
RSpec.describe Rubino::Tools::ShellTool do
  subject(:tool) { described_class.new }

  # Shrink the cap so the test trips it in a handful of 64KiB reads and stays
  # fast; the production default (2MB) uses the same code path.
  let(:cap) { 256_000 }

  before do
    allow(Rubino.configuration)
      .to receive(:tool_output_capture_max_bytes).and_return(cap)
  end

  def rss_kb
    `ps -o rss= -p #{Process.pid}`.to_i
  end

  it "caps a fast NUL producer (cat /dev/zero) and TERMINATES it, bounded RAM" do
    before_rss = rss_kb
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    out = tool.call("command" => "cat /dev/zero", "timeout" => 10)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    text = out[:output]

    # Returned promptly — the producer was killed at the cap, NOT drained to
    # the 10s timeout.
    expect(elapsed).to be < 5
    expect(out[:timed_out]).to be_falsey

    # Retained output is bounded (cap + a small marker/UTF-8 margin), not GBs.
    expect(text.bytesize).to be <= cap + 4_096

    # Carries the capped marker so the model knows output was cut + the command
    # terminated.
    expect(text).to include("output capped at #{cap} bytes")
    expect(text).to include("command terminated")

    # RAM did not balloon. /dev/zero used to drive +1.3GB; a few MB of slack is
    # plenty of headroom while still failing the old unbounded behavior.
    expect(rss_kb - before_rss).to be < 200_000 # < ~200 MB
  end

  it "caps an unbounded single mega-line (no newline) producer" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = tool.call("command" => "yes | tr -d '\\n'", "timeout" => 10)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    text = out[:output]

    expect(elapsed).to be < 5
    expect(text.bytesize).to be <= cap + 4_096
    expect(text).to include("output capped at #{cap} bytes")
    # Head+tail preserved around the elision marker.
    expect(text).to start_with("y")
    expect(text).to end_with("y")
  end

  it "leaves a normal small command's output unchanged (regression)" do
    out = tool.call("command" => "printf 'hello world'", "timeout" => 5)
    expect(out[:output]).to eq("hello world")
    expect(out[:output]).not_to include("output capped")
    expect(out[:exit_code]).to eq(0)
  end

  it "does not cap output that fits comfortably under the cap" do
    # ~100 lines, well under 256KB — must pass through verbatim, no marker.
    out = tool.call("command" => "seq 1 100", "timeout" => 5)
    expect(out[:output]).to include("1\n").and include("100")
    expect(out[:output]).not_to include("output capped")
    expect(out[:exit_code]).to eq(0)
  end
end
