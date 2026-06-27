# frozen_string_literal: true

# Slice 0 of the interactive-shell port (Hermes parity): ShellRegistry can spawn
# a background command on a REAL pseudo-terminal (pty: true) so tty-aware tools,
# `[ -t 0 ]` checks and interactive prompts work where a plain pipe (stdin
# DEVNULL / non-tty) cannot. These drive the actual registry primitives.
RSpec.describe Rubino::Tools::ShellRegistry, "#spawn (PTY / interactive mode)" do
  subject(:registry) { described_class.instance }

  after { registry.reset! if registry.respond_to?(:reset!) }

  # Poll the buffer until it contains +needle+ or the deadline passes — a real
  # process + PTY has scheduling latency, so a fixed sleep would be flaky.
  def wait_for(entry, needle, timeout: 5.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      out = registry.read_all(entry)
      return out if out.include?(needle)
      break out if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  it "runs the child on a controlling terminal and delivers stdin (interactive prompt)" do
    entry = registry.spawn(
      command: %(printf 'name? '; read N; echo "got=$N"; echo "istty=$([ -t 0 ] && echo yes || echo no)"),
      cwd: "/tmp", pty: true
    )
    expect(entry.pty).to be(true)
    expect(entry.pgid).to eq(entry.pid) # PTY.spawn makes the child a session leader

    # The prompt is printed; feed the answer through the PTY master.
    wait_for(entry, "name?")
    registry.write_input(entry, "Alice")

    out = wait_for(entry, "got=Alice")
    expect(out).to include("got=Alice")   # the process RECEIVED our input
    expect(out).to include("istty=yes")   # ...and it ran on a real tty (pipe → "no")
  end

  it "still spawns a non-interactive pipe shell by default (no regression)" do
    entry = registry.spawn(command: %(echo hello-pipe), cwd: "/tmp")
    expect(entry.pty).to be_falsey
    expect(wait_for(entry, "hello-pipe")).to include("hello-pipe")
  end

  # Regression: closing the stdin of a FINISHED pty shell must not raise. The
  # child is gone, so EOT-on-the-master would raise Errno::EIO; close_stdin must
  # close the fd instead (also reclaiming the leaked master). retire/prune call
  # this under the registry mutex from `any?`, so a raise here is a live crash.
  it "closes a finished PTY shell's stdin without raising (EIO on a dead master)" do
    entry = registry.spawn(command: %(echo bye), cwd: "/tmp", pty: true)
    wait_for(entry, "bye")
    entry.wait_thr.join(5) # ensure the child has exited

    expect { registry.close_stdin(entry) }.not_to raise_error
    expect(entry.stdin.closed?).to be(true) # the master fd was reclaimed, not leaked
  end
end
