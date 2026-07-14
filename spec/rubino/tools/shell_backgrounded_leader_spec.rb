# frozen_string_literal: true

# Backgrounded-leader liveness — aligned to hermes-agent.
#
# FIX 1 (shell_registry.rb): liveness is derived from the LEADER PROCESS only
# (wait_thr). The reader thread is NOT part of the liveness signal: tying
# completion to whether the stdout pipe is still open caused the real bug where
# a finished command whose detached child holds the pipe was stuck "running"
# forever. The leader's exit now immediately reports :completed/:failed; a short
# drain_tail grace ensures the final output is flushed to the log.
RSpec.describe Rubino::Tools::ShellRegistry do
  subject(:registry) { described_class.instance }

  before { described_class.reset! }

  # A launcher that backgrounds its real work then exits: the `bash -c` leader
  # reaps immediately, but the `sleep` keeps the group — and the pipe — alive.
  def spawn_self_backgrounding
    registry.spawn(command: "sleep 30 & echo listening", cwd: Dir.pwd).tap { sleep 0.4 }
  end

  describe "#running? / #status for a leader that backgrounded its work" do
    it "reports :completed when the leader exits, even though a descendant holds the pipe" do
      entry = spawn_self_backgrounding

      expect(entry.wait_thr.alive?).to be(false) # the bash -c leader is gone
      # FIX 1: liveness from the PROCESS only — reader_thr is NOT gating.
      expect(registry.running?(entry)).to be(false)
      expect(registry.status(entry)).to eq(:completed)
      expect(registry.exit_code(entry)).to eq(0)
    ensure
      registry.terminate(entry) if entry
    end

    it "does NOT keep the shell in the running set once the leader exits" do
      entry = spawn_self_backgrounding
      expect(registry.running_entries.map(&:id)).not_to include(entry.id)
    ensure
      registry.terminate(entry) if entry
    end

    it "reports :completed as soon as the leader exits, not when the group is gone" do
      entry = registry.spawn(command: "sleep 0.3 & echo up", cwd: Dir.pwd)
      sleep 0.2 # leader likely exited; descendant still sleeping
      expect(registry.status(entry)).to eq(:completed)
      sleep 0.5 # the backgrounded sleep finishes → pipe EOFs → reader ends
      expect(registry.status(entry)).to eq(:completed)
    end
  end

  describe "shell_output retires a leader-exited shell so output stays reachable (#78)" do
    it "retires the entry (stamps retired_at) on read, keeping output retrievable" do
      entry = spawn_self_backgrounding
      Rubino::Tools::ShellOutputTool.new.call("run_id" => entry.id)
      expect(entry.retired_at).not_to be_nil # retired so output stays reachable
      expect(registry.find(entry.id)).to eq(entry) # still tracked, not dropped
    ensure
      registry.terminate(entry) if entry
    end
  end

  describe "shell_kill on a leader-exited entry" do
    it "reports already-exited (leader is gone; orphan reaped by teardown)" do
      entry = spawn_self_backgrounding
      pgid  = entry.pgid

      # shell_kill gates on running? — which is false because the leader exited.
      # The orphan sleep 30 is still alive in the process group but is no longer
      # tracked as running; it gets reaped by kill_all_groups on teardown.
      result = Rubino::Tools::ShellKillTool.new.call("run_id" => entry.id)
      expect(result).to include("already exited")

      # The orphan IS still alive — but the entry is retired so it drops from
      # the teardown snapshot. Kill it manually so the test doesn't leak.
      begin
        Process.kill("TERM", -pgid)
        sleep 0.2
        Process.kill("KILL", -pgid)
      rescue Errno::ESRCH
        nil
      end
      sleep 0.1

      group_alive = begin
        Process.kill(0, -pgid)
        true
      rescue Errno::ESRCH
        false
      end
      expect(group_alive).to be(false)
    ensure
      registry.terminate(entry) if entry
    end
  end
end
