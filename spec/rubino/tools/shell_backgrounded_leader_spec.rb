# frozen_string_literal: true

# Backgrounded-leader liveness regression.
#
# A long-lived server is frequently NOT the `bash -c` LEADER the registry waits
# on: a launcher that backgrounds the real process (`server & echo up`, an
# `npm`/`yarn` wrapper, a double-fork that stays in the group) exits while the
# server keeps running and holding the merged stdout/stderr pipe. Keying
# liveness off the leader ALONE reported these :completed the instant the
# launcher exited — so shell_output retired+closed them mid-flight, orphaning a
# live server. The model then read "completed", restarted it, hit the port the
# orphan still held, crashed, and looped. ShellRegistry#running? is now the one
# liveness oracle (leader alive OR the output reader still draining), so a
# self-backgrounding server reads :running until it (or its group) actually dies.
RSpec.describe Rubino::Tools::ShellRegistry do
  subject(:registry) { described_class.instance }

  before { described_class.reset! }

  # A launcher that backgrounds its real work then exits: the `bash -c` leader
  # reaps immediately, but the `sleep` keeps the group — and the pipe — alive.
  def spawn_self_backgrounding
    registry.spawn(command: "sleep 30 & echo listening", cwd: Dir.pwd).tap { sleep 0.4 }
  end

  describe "#running? / #status for a leader that backgrounded its work" do
    it "reports :running while a descendant is still alive, though the leader exited" do
      entry = spawn_self_backgrounding

      expect(entry.wait_thr.alive?).to be(false) # the bash -c leader is gone
      expect(registry.running?(entry)).to be(true) # but the work is not
      expect(registry.status(entry)).to eq(:running)
      expect(registry.exit_code(entry)).to be_nil # no terminal code while running
    ensure
      registry.terminate(entry) if entry
    end

    it "keeps the shell in the running set (never silently dropped)" do
      entry = spawn_self_backgrounding
      expect(registry.running_entries.map(&:id)).to include(entry.id)
    ensure
      registry.terminate(entry) if entry
    end

    it "becomes terminal only once the whole group is gone" do
      entry = registry.spawn(command: "sleep 0.3 & echo up", cwd: Dir.pwd)
      sleep 0.2
      expect(registry.status(entry)).to eq(:running)
      sleep 0.5 # the backgrounded sleep finishes → pipe EOFs → reader ends
      expect(registry.status(entry)).to eq(:completed)
    end
  end

  describe "shell_output does not retire a self-backgrounding server mid-flight" do
    it "leaves the entry live (retired_at nil) after a read" do
      entry = spawn_self_backgrounding
      Rubino::Tools::ShellOutputTool.new.call("run_id" => entry.id)
      expect(entry.retired_at).to be_nil
      expect(registry.find(entry.id)).to eq(entry) # still tracked, not dropped
    ensure
      registry.terminate(entry) if entry
    end
  end

  describe "shell_kill terminates a leader-exited-but-alive server's group" do
    it "actually kills the orphan instead of reporting 'already exited'" do
      entry = spawn_self_backgrounding
      pgid  = entry.pgid

      result = Rubino::Tools::ShellKillTool.new.call("run_id" => entry.id)
      expect(result).to include("terminated")
      sleep 0.3

      group_alive = begin
        Process.kill(0, -pgid)
        true
      rescue Errno::ESRCH
        false
      end
      expect(group_alive).to be(false)
    end
  end
end
