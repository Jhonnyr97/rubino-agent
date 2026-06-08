# frozen_string_literal: true

RSpec.describe "Shell input tool" do
  let(:shell)        { Rubino::Tools::ShellTool.new }
  let(:shell_output) { Rubino::Tools::ShellOutputTool.new }
  let(:shell_input)  { Rubino::Tools::ShellInputTool.new }
  let(:registry)     { Rubino::Tools::ShellRegistry.instance }

  def payload(result) = result.is_a?(Hash) ? result[:output] : result

  # Polls shell_output until `needle` shows up (or the budget runs out), so the
  # tests don't race the reader thread. Returns the accumulated text.
  def wait_for_output(run_id, needle, tries: 50)
    acc = +""
    tries.times do
      acc << payload(shell_output.call("run_id" => run_id, "mode" => "all"))
      return acc if acc.include?(needle)

      sleep 0.05
    end
    acc
  end

  describe "answering a prompt on a background shell's stdin" do
    it "delivers a line the running process reads, with the newline appended" do
      start = shell.call(
        "command" => "read line; echo \"got:$line\"",
        "run_in_background" => true
      )
      run_id = start[/bg_\h+/]
      expect(run_id).not_to be_nil

      res = shell_input.call("run_id" => run_id, "text" => "yes")
      expect(res).to include("wrote").and include("byte")

      expect(wait_for_output(run_id, "got:yes")).to include("got:yes")
    end

    it "answers a Y/N read -p prompt" do
      start = shell.call(
        "command" => "read -p 'Delete all? (y/n) ' a; echo \"you-said:[$a]\"",
        "run_in_background" => true
      )
      run_id = start[/bg_\h+/]

      shell_input.call("run_id" => run_id, "text" => "y")
      expect(wait_for_output(run_id, "you-said:[y]")).to include("you-said:[y]")
    end

    it "answers a menu selection" do
      start = shell.call(
        "command" => "read -p 'Choice: ' c; echo \"region=$c\"",
        "run_in_background" => true
      )
      run_id = start[/bg_\h+/]

      shell_input.call("run_id" => run_id, "text" => "2")
      expect(wait_for_output(run_id, "region=2")).to include("region=2")
    end
  end

  describe "enter: false (raw bytes, no newline)" do
    it "does not append a newline so the reader keeps blocking" do
      start = shell.call(
        "command" => "read line; echo \"got:[$line]\"",
        "run_in_background" => true
      )
      run_id = start[/bg_\h+/]

      res = shell_input.call("run_id" => run_id, "text" => "ab", "enter" => false)
      expect(res).to include("wrote 2 bytes")

      # No newline yet → `read` is still blocked, nothing echoed.
      sleep 0.2
      expect(payload(shell_output.call("run_id" => run_id, "mode" => "all")))
        .not_to include("got:")

      # Send the rest + newline → the line completes as "abcd".
      shell_input.call("run_id" => run_id, "text" => "cd", "enter" => true)
      expect(wait_for_output(run_id, "got:[abcd]")).to include("got:[abcd]")
    end
  end

  describe "eof: true (close stdin)" do
    it "lets a command that reads until EOF finish" do
      start = shell.call(
        "command" => "cat; echo END",
        "run_in_background" => true
      )
      run_id = start[/bg_\h+/]

      res = shell_input.call("run_id" => run_id, "text" => "hello", "eof" => true)
      expect(res).to include("EOF sent")

      out = wait_for_output(run_id, "END")
      expect(out).to include("hello").and include("END")
    end
  end

  describe "error handling" do
    it "errors on unknown run_id" do
      expect(shell_input.call("run_id" => "bg_deadbeef", "text" => "x"))
        .to include("no background shell")
    end

    it "errors when run_id is missing" do
      expect(shell_input.call("text" => "x")).to include("run_id is required")
    end

    it "errors when the process has already exited" do
      start  = shell.call("command" => "echo quick", "run_in_background" => true)
      run_id = start[/bg_\h+/]

      # Let it finish — shell_output drops the entry once it sees a terminal
      # status, so use the registry directly to wait.
      50.times do
        entry = registry.find(run_id)
        break if entry.nil? || registry.status(entry) != :running

        sleep 0.05
      end

      res = shell_input.call("run_id" => run_id, "text" => "x")
      # Either already exited, or the reader already reaped+removed the entry.
      expect(res).to match(/already exited|no background shell/)
    end
  end
end
