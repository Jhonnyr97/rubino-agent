# frozen_string_literal: true

require "timeout"

# Trap-safe parent-death reaping (#478).
#
# The interactive HUP/TERM teardown trap (ChatCommand#install_session_end_traps)
# used to call BackgroundTasks#cancel_all, which calls #running (and #stop_entry,
# and the pre-fix #kill_all_groups) — all guarded by Mutex#synchronize. Ruby
# FORBIDS Mutex#synchronize from a signal-trap context: it raises
#   ThreadError: can't be called from trap context
# The trap died with that backtrace and SKIPPED the #465 shell reaper, so on a
# non-PTY death (kill -TERM, systemd, SIGHUP on terminal close) a background
# subagent's shell (its own pgroup) reparented to init (PID 1) as a LIVE orphan.
#
# The fix: the trap NO LONGER touches a mutex. It reaps the tracked shell groups
# via ShellRegistry#kill_all_groups, which now reads a lock-free, atomically
# swapped @pgid_snapshot (rebuilt under the mutex by writers) and only calls
# Process.kill / sleep — both async-signal-safe. The clean-quit `ensure` path
# still goes through #cancel_all (normal thread context), so the cooperative
# subagent-gate cancel + reaping on clean quit is unchanged.
RSpec.describe Rubino::Tools::ShellRegistry do
  let(:shell_reg) { described_class.instance }

  before { described_class.reset! }
  after  { described_class.reset! }

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def spawn_tracked_shell
    pid = Process.spawn("bash", "-c", "sleep 30",
                        pgroup: true, out: File::NULL, err: File::NULL)
    Process.detach(pid)
    shell_reg.register_pgid(pid)
    pid
  end

  def reap_group(pgid)
    return unless pgid

    Process.kill("KILL", -pgid)
    Process.waitpid(pgid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  describe "ShellRegistry#kill_all_groups is lock-free (no Mutex on the trap path)" do
    it "does NOT take the registry mutex — it reaps even while another thread " \
       "holds that mutex (a mutex-taking reaper would deadlock/hang here)" do
      pgid = spawn_tracked_shell
      expect(alive?(pgid)).to be(true)

      mutex = shell_reg.instance_variable_get(:@mutex)
      held  = Thread.new { mutex.synchronize { sleep 5 } }
      sleep 0.05 until mutex.locked? # the other thread now owns the mutex

      result = nil
      # If #kill_all_groups still did @mutex.synchronize { ... } it would block
      # on the held mutex and blow the timeout. The lock-free snapshot read lets
      # it run and signal the group immediately.
      expect do
        Timeout.timeout(3) { result = shell_reg.kill_all_groups(grace: 0) }
      end.not_to raise_error

      expect(result).to eq([pgid])
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      sleep(0.02) while alive?(pgid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      expect(alive?(pgid)).to be(false)
    ensure
      held&.kill
      held&.join
      reap_group(pgid)
    end

    it "keeps the lock-free snapshot in sync with register/unregister/remove" do
      shell_reg.register_pgid(111)
      shell_reg.register_pgid(222)
      expect(shell_reg.kill_all_groups(grace: 0).sort).to eq([111, 222])

      shell_reg.unregister_pgid(111)
      expect(shell_reg.kill_all_groups(grace: 0)).to eq([222])
    end
  end

  describe "the actual SIGTERM teardown trap under a REAL signal (forked)" do
    # A PLAIN lock-free stand-in for the runner — NOT an RSpec double. An
    # instance_double records every call under rspec-mocks' OWN mutex
    # (OrderGroup#synchronize), which is itself forbidden in a trap context — so
    # a double would mask the real-runner path (whose #cancel! only flips
    # lock-free booleans) behind a spurious ThreadError of its own. This mirrors
    # the production Runner#cancel!/#end_session! contract: no locking.
    let(:runner) do
      Class.new do
        def cancel!(*) = nil
        def end_session! = nil
      end.new
    end

    # Fork a child that installs the PRODUCTION HUP/TERM trap, tracks a real
    # shell process group, then SIGTERMs itself. Because the handler is the real
    # one (ending in exit(0)) and runs in a genuine trap context, this is the
    # faithful reproduction: pre-fix the trap hit Mutex#synchronize via
    # #cancel_all → ThreadError → the handler died WITHOUT reaping and exited
    # non-zero, leaving the shell group an orphan. Post-fix the handler reaps via
    # the lock-free #kill_all_groups, exits 0, and the group is dead.
    it "does NOT raise ThreadError in the trap and reaps the child shell group; " \
       "the process exits 0" do
      skip "no SIGTERM on this platform" unless Signal.list.key?("TERM")
      skip "fork unavailable on this platform" unless Process.respond_to?(:fork)

      grandchild_pgid_r, grandchild_pgid_w = IO.pipe

      child = fork do
        grandchild_pgid_r.close
        # The production handler ends in Kernel#exit(0). In a forked RSpec worker
        # that would fire RSpec/WebMock/SimpleCov at_exit hooks and pollute the
        # status to 1 — a false failure. Redirect Kernel#exit to exit! (skip
        # at_exit) so the status we observe is the one the TRAP itself sets, and
        # the production handler body stays byte-for-byte unchanged.
        Kernel.module_eval do
          define_method(:exit) { |code = true| exit!(code) }
        end
        # A real long-lived shell in its own process group — the orphan-to-be.
        gc = Process.spawn("bash", "-c", "sleep 30",
                           pgroup: true, out: File::NULL, err: File::NULL)
        Process.detach(gc)
        described_class.instance.register_pgid(gc)
        grandchild_pgid_w.write(gc.to_s)
        grandchild_pgid_w.close

        cmd = Rubino::CLI::ChatCommand.new("query" => "hi")
        cmd.send(:install_session_end_traps, runner)
        # Deliver a REAL SIGTERM to ourselves — the handler runs in a true trap
        # context (where Mutex#synchronize would raise ThreadError). Pre-fix it
        # raised there, the trap died WITHOUT exit, and the child fell through to
        # exit!(42). Post-fix the handler reaps lock-free and exits 0.
        Process.kill("TERM", Process.pid)
        sleep 2 # give the handler time; it should exit(0) before this elapses
        exit!(42) # reached only if the trap NEVER ran/exited — a failure
      end

      grandchild_pgid_w.close
      gc_pgid = grandchild_pgid_r.read.to_i
      grandchild_pgid_r.close

      _, status = Process.waitpid2(child)

      expect(status.exitstatus).to eq(0),
                                   "trap exited #{status.inspect} (non-zero ⇒ ThreadError or crash)"

      # The reaped shell group must be gone (no orphan reparented to init).
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      sleep(0.02) while alive?(gc_pgid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      expect(alive?(gc_pgid)).to be(false)
    ensure
      reap_group(gc_pgid) if defined?(gc_pgid)
    end
  end
end
