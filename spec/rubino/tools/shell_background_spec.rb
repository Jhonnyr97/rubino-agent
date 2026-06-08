# frozen_string_literal: true

RSpec.describe "Shell background tools" do
  let(:shell)        { Rubino::Tools::ShellTool.new }
  let(:shell_output) { Rubino::Tools::ShellOutputTool.new }
  let(:shell_kill)   { Rubino::Tools::ShellKillTool.new }
  let(:registry)     { Rubino::Tools::ShellRegistry.instance }

  def payload(result) = result.is_a?(Hash) ? result[:output] : result

  describe "shell foreground" do
    it "runs a short command and captures stdout" do
      expect(payload(shell.call("command" => "echo hello_fg"))).to include("hello_fg")
    end

    it "honours a short timeout and SIGTERMs the runaway" do
      expect(payload(shell.call("command" => "sleep 5", "timeout" => 1))).to include("timed out after 1s")
    end

    it "captures non-zero exit code" do
      expect(payload(shell.call("command" => "false"))).to include("Exit code: 1")
    end
  end

  describe "shell background → output → kill" do
    it "spawns a background process, reads incremental output, then kills it" do
      start = shell.call(
        "command" => "for i in 1 2 3 4 5 6 7 8 9 10; do echo step$i; sleep 0.2; done",
        "run_in_background" => true
      )
      expect(start).to match(/Started background shell (bg_\h+)/)
      run_id = start[/bg_\h+/]

      # wait for the first chunks to arrive
      sleep 0.5

      first = shell_output.call("run_id" => run_id)
      expect(first).to include("status=running")
      expect(first).to match(/step\d/)

      # next read should be incremental (no repeat of already-seen lines)
      sleep 0.4
      second = shell_output.call("run_id" => run_id)
      expect(second).to include("status=running")

      killed = shell_kill.call("run_id" => run_id)
      expect(killed).to include("terminated")

      # after the kill the registry entry is gone
      expect(shell_output.call("run_id" => run_id)).to include("no background shell")
    end

    it "lets a short background command finish on its own and reports exit" do
      start = shell.call("command" => "echo done_bg", "run_in_background" => true)
      run_id = start[/bg_\h+/]

      # wait for the process to exit
      30.times do
        break if registry.status(registry.find(run_id) || next) != :running
        sleep 0.1
      end

      out = shell_output.call("run_id" => run_id, "mode" => "all")
      expect(out).to include("done_bg")
      expect(out).to match(/status=(completed|failed) exit=\d/)
    end

    it "errors out on unknown run_id" do
      expect(shell_output.call("run_id" => "bg_deadbeef")).to include("no background shell")
      expect(shell_kill.call("run_id"   => "bg_deadbeef")).to include("no background shell")
    end
  end
end
