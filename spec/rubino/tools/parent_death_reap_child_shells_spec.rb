# frozen_string_literal: true

# Parent-death child-shell reaping (MED-2).
#
# When the PARENT rubino exits while a (background) subagent has a live OS
# shell process — e.g. a child ran `sleep 400` through the shell tool — the
# pre-fix #cancel_all only flipped cancel tokens and trusted each child THREAD
# to observe the token and reap its own shell "within one wake tick". On
# parent-DEATH the process exits BEFORE the child thread reaches that
# checkpoint, so the shell (its own process group) reparents to init (PID 1)
# and survives as an ORPHAN. The /agents --stop control path passes because the
# parent stays ALIVE there; the gap is only on parent-DEATH teardown.
#
# The fix tracks every live foreground shell pgid in ShellRegistry and has
# #cancel_all SYNCHRONOUSLY SIGTERM/SIGKILL the tracked groups (mirroring the
# Python Hermes _kill_process: killpg TERM → grace → KILL), so the SAME
# parent-death edges that already call #cancel_all (clean quit, HUP/TERM trap,
# REPL break) leave no surviving shell.
RSpec.describe Rubino::Tools::BackgroundTasks do
  let(:registry)  { described_class.instance }
  let(:shell_reg) { Rubino::Tools::ShellRegistry.instance }

  before do
    described_class.reset!
    Rubino::Tools::ShellRegistry.reset!
  end

  after do
    described_class.reset!
    Rubino::Tools::ShellRegistry.reset!
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # Spawn a real, long-lived shell in its OWN process group exactly as
  # ShellTool#execute_foreground does (pgroup: true → pgid == pid), and track
  # it the same way the tool now does. Returns the pgid. The process would
  # outlive the parent if nothing reaped its group — the orphan under test.
  def spawn_tracked_shell
    pid = Process.spawn("bash", "-c", "sleep 30",
                        pgroup: true, out: File::NULL, err: File::NULL)
    # Detach so the signalled process is REAPED (not left a zombie) once
    # cancel_all kills it — Process.kill(0, pid) keeps returning true for an
    # unreaped zombie, which would mask a successful kill. Mirrors how the real
    # foreground path's drain/wait thread reaps the child.
    Process.detach(pid)
    shell_reg.register_pgid(pid)
    pid
  end

  # Best-effort teardown: hard-kill the group and reap so no spec leaks a real
  # process even if its assertion failed before the synchronous reap ran.
  def reap_group(pgid)
    return unless pgid

    Process.kill("KILL", -pgid)
    Process.waitpid(pgid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  it "REPRODUCES the orphan and PROVES the fix: a live child shell group is " \
     "terminated synchronously on #cancel_all (no survivor)" do
    pgid = spawn_tracked_shell
    expect(alive?(pgid)).to be(true) # the orphan-to-be is running

    registry.cancel_all # the parent-death teardown seam

    # Synchronous reap: the group is gone right after cancel_all returns —
    # not "eventually" once some child thread wakes (the pre-fix behaviour
    # that let it reparent to init).
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep(0.02) while alive?(pgid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    expect(alive?(pgid)).to be(false)
  ensure
    reap_group(pgid)
  end

  it "reaps EVERY tracked group in one #cancel_all" do
    pgids = Array.new(3) { spawn_tracked_shell }
    expect(pgids.all? { |p| alive?(p) }).to be(true)

    registry.cancel_all

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep(0.02) while pgids.any? { |p| alive?(p) } &&
                      Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    expect(pgids.any? { |p| alive?(p) }).to be(false)
  ensure
    pgids&.each { |p| reap_group(p) }
  end

  it "routes the synchronous reap THROUGH #cancel_all (so every parent-death " \
     "edge that calls it reaps, not only the explicit stop paths)" do
    expect(shell_reg).to receive(:kill_all_groups).once.and_call_original
    registry.cancel_all
  end

  describe "ShellRegistry#kill_all_groups" do
    it "is a no-op when nothing is tracked" do
      expect(shell_reg.kill_all_groups).to eq([])
    end

    it "SIGTERMs then SIGKILLs every tracked foreground and background group" do
      shell_reg.register_pgid(111)
      shell_reg.register_pgid(222)
      sent = []
      allow(Process).to receive(:kill) { |sig, target| sent << [sig, target] }

      result = shell_reg.kill_all_groups(grace: 0)

      expect(result).to contain_exactly(111, 222)
      expect(sent).to contain_exactly(
        ["TERM", -111], ["TERM", -222], ["KILL", -111], ["KILL", -222]
      )
    end

    it "swallows ESRCH/EPERM on an already-dead group (idempotent)" do
      shell_reg.register_pgid(333)
      allow(Process).to receive(:kill).and_raise(Errno::ESRCH)
      expect { shell_reg.kill_all_groups(grace: 0) }.not_to raise_error
    end
  end

  describe "ShellRegistry pgid bookkeeping" do
    it "drops a group on #unregister_pgid so a normally-reaped shell is not re-killed" do
      shell_reg.register_pgid(444)
      shell_reg.unregister_pgid(444)
      expect(shell_reg.kill_all_groups(grace: 0)).to eq([])
    end
  end
end
