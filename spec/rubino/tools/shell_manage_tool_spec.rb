# frozen_string_literal: true

# shell_manage is the single background-shell management surface: it merges the
# former shell_output / shell_tail / shell_input / shell_kill tools behind one
# `action` parameter (mirroring Hermes' `process(action:)`). These specs port
# the meaningful coverage of the four tools it replaced, plus the per-action
# approval split (output/tail/wait read-only → unprompted; input/kill → gated).
RSpec.describe Rubino::Tools::ShellManageTool do
  subject(:manage) { described_class.new }

  let(:shell)    { Rubino::Tools::ShellTool.new }
  let(:registry) { Rubino::Tools::ShellRegistry.instance }

  def payload(result) = result.is_a?(Hash) ? result[:output] : result

  def output(run_id, mode: "new")
    manage.call("run_id" => run_id, "action" => "output", "mode" => mode)
  end

  # Polls the output action until `needle` shows up (or the budget runs out) so
  # the tests don't race the reader thread. Returns the accumulated text.
  def wait_for_output(run_id, needle, tries: 50)
    acc = +""
    tries.times do
      acc << payload(output(run_id, mode: "all"))
      return acc if acc.include?(needle)

      sleep 0.05
    end
    acc
  end

  after do
    registry.instance_variable_get(:@entries).keys.each { |id| registry.remove(id) }
  end

  describe "schema" do
    it "requires run_id and action, but not the action-scoped params" do
      required = manage.input_schema[:required] || []
      expect(required).to include("run_id", "action")
      expect(required).not_to include("input", "mode", "enter", "eof", "timeout")
    end

    it "advertises the action enum" do
      desc = manage.input_schema.dig(:properties, :action, :description)
      expect(desc).to include("output", "tail", "wait", "input", "kill")
    end
  end

  describe "param validation" do
    it "rejects a call with no run_id" do
      expect(manage.call("action" => "output")).to include("run_id is required")
    end

    it "rejects an unknown action" do
      expect(manage.call("run_id" => "bg_x", "action" => "frobnicate"))
        .to include("unknown action")
    end

    it "returns the shared no-such-shell error for an unknown run_id (every action)" do
      %w[output tail wait input kill].each do |action|
        res = manage.call("run_id" => "bg_deadbeef", "action" => action, "input" => "x", "timeout" => 1)
        expect(payload(res)).to include("no background shell with run_id=bg_deadbeef")
      end
    end
  end

  describe "action: output" do
    it "returns incremental bytes by default and the full buffer with mode:all" do
      start = shell.call("command" => "echo out_marker; sleep 0.4; echo second",
                         "run_in_background" => true)
      run_id = start[/bg_\h+/]

      # Poll incremental `new` reads until out_marker shows — this drains the
      # per-run_id read cursor PAST it.
      acc = +""
      50.times do
        acc << payload(output(run_id))
        break if acc.include?("out_marker")

        sleep 0.05
      end
      expect(acc).to include("out_marker")

      # The NEXT `new` read is incremental — it does not repeat out_marker.
      expect(payload(output(run_id))).not_to include("out_marker")

      # `all` still returns the whole buffer, including the earlier line.
      expect(payload(output(run_id, mode: "all"))).to include("out_marker")
    end

    it "keeps a completed shell's output retrievable with a terminal status (#78)" do
      start  = shell.call("command" => "echo done_marker", "run_in_background" => true)
      run_id = start[/bg_\h+/]

      expect(wait_for_output(run_id, "done_marker")).to include("done_marker")
      second = payload(output(run_id, mode: "all"))
      expect(second).not_to include("no background shell")
      expect(second).to match(/status=(completed|failed)/)
    end
  end

  describe "action: tail" do
    it "returns immediately when bytes are already buffered" do
      start = shell.call("command" => "echo first; sleep 0.3; echo second",
                         "run_in_background" => true)
      run_id = start[/bg_\h+/]
      sleep 0.1

      res = manage.call("run_id" => run_id, "action" => "tail", "timeout" => 5)
      expect(res[:output]).to include("first")
      expect(res[:metrics]).to match(/\d+B/)
    end

    it "blocks until the next chunk arrives" do
      start  = shell.call("command" => "sleep 0.4; echo late", "run_in_background" => true)
      run_id = start[/bg_\h+/]

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      res     = manage.call("run_id" => run_id, "action" => "tail", "timeout" => 5)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(res[:output]).to include("late")
      expect(elapsed).to be >= 0.3
    end

    it "reports 'no new output before deadline' when the timeout fires" do
      start  = shell.call("command" => "sleep 3; echo never", "run_in_background" => true)
      run_id = start[/bg_\h+/]

      res = manage.call("run_id" => run_id, "action" => "tail", "timeout" => 1)
      expect(res[:output]).to include("no new output before deadline")
      expect(res[:output]).not_to include("never")
    end
  end

  # `wait` is the hermes process(action=wait) parity primitive: block until the
  # process EXITS, ignoring intermediate output. This is the fix for the
  # shell_manage doom-loop — with only `tail` (which returns on every new line) a
  # model watching a chatty long job re-polls per line; `wait` awaits it in ONE call.
  describe "action: wait" do
    it "blocks until the process EXITS and returns final output + exit code" do
      start  = shell.call("command" => "echo step1; sleep 0.2; echo step2; sleep 0.2; echo DONE_WAIT",
                          "run_in_background" => true)
      run_id = start[/bg_\h+/]

      res = manage.call("run_id" => run_id, "action" => "wait", "timeout" => 10)

      # Returned only AFTER exit: terminal status + exit code present.
      expect(res[:output]).to match(/status=(completed|failed)/)
      expect(res[:exit_code]).to eq(0)
      # The whole run was captured in one call, through to the final line.
      expect(payload(res)).to include("DONE_WAIT")
    end

    it "does NOT return on intermediate output the way tail does (doom-loop fix)" do
      # Prints immediately, then keeps running: tail would return on the buffered
      # "progress" at once; wait must block through the sleep until exit.
      start  = shell.call("command" => "echo progress; sleep 0.6; echo FINISHED_WAIT",
                          "run_in_background" => true)
      run_id = start[/bg_\h+/]
      sleep 0.15 # let "progress" buffer

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      res     = manage.call("run_id" => run_id, "action" => "wait", "timeout" => 10)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be >= 0.4 # blocked through the sleep, not returned on "progress"
      expect(res[:exit_code]).to eq(0)
      expect(payload(res)).to include("FINISHED_WAIT")
    end

    it "reports 'still running' (NOT an error) when the timeout fires before exit" do
      start  = shell.call("command" => "sleep 3; echo never_wait", "run_in_background" => true)
      run_id = start[/bg_\h+/]

      res = manage.call("run_id" => run_id, "action" => "wait", "timeout" => 1)

      expect(res[:output]).to include("still running")
      expect(res[:error_code]).to be_nil # a running job at the deadline is not a failure
      expect(res[:output]).not_to include("never_wait")
    end

    it "marks the completion consumed so the async notice is deduped after wait delivers the exit" do
      start  = shell.call("command" => "echo quick_wait", "run_in_background" => true)
      run_id = start[/bg_\h+/]
      entry  = registry.find(run_id)

      manage.call("run_id" => run_id, "action" => "wait", "timeout" => 5)

      # The fire-once flag #notify_completion checks is set → no double notice.
      expect(entry.notified).to be(true)
    end
  end

  describe "action: input" do
    it "delivers a line the running process reads, appending a newline" do
      start  = shell.call("command" => "read line; echo \"got:$line\"", "run_in_background" => true)
      run_id = start[/bg_\h+/]

      res = manage.call("run_id" => run_id, "action" => "input", "input" => "yes")
      expect(res).to include("wrote").and include("byte")
      expect(wait_for_output(run_id, "got:yes")).to include("got:yes")
    end

    it "honours enter:false (raw bytes, no newline) then completes on the next line" do
      start  = shell.call("command" => "read line; echo \"got:[$line]\"", "run_in_background" => true)
      run_id = start[/bg_\h+/]

      res = manage.call("run_id" => run_id, "action" => "input", "input" => "ab", "enter" => false)
      expect(res).to include("wrote 2 bytes")

      sleep 0.2
      expect(payload(output(run_id, mode: "all"))).not_to include("got:")

      manage.call("run_id" => run_id, "action" => "input", "input" => "cd", "enter" => true)
      expect(wait_for_output(run_id, "got:[abcd]")).to include("got:[abcd]")
    end

    it "closes stdin with eof:true so a read-until-EOF command finishes" do
      start  = shell.call("command" => "cat; echo END", "run_in_background" => true)
      run_id = start[/bg_\h+/]

      res = manage.call("run_id" => run_id, "action" => "input", "input" => "hello", "eof" => true)
      expect(res).to include("EOF sent")

      out = wait_for_output(run_id, "END")
      expect(out).to include("hello").and include("END")
    end

    it "rejects action:input with no input text (and no eof)" do
      start  = shell.call("command" => "read line; echo done", "run_in_background" => true)
      run_id = start[/bg_\h+/]

      res = manage.call("run_id" => run_id, "action" => "input")
      expect(res).to include("requires `input` text")
    end

    it "errors when the process has already exited" do
      start  = shell.call("command" => "echo quick", "run_in_background" => true)
      run_id = start[/bg_\h+/]

      50.times do
        entry = registry.find(run_id)
        break if entry.nil? || registry.status(entry) != :running

        sleep 0.05
      end

      res = manage.call("run_id" => run_id, "action" => "input", "input" => "x")
      expect(res).to match(/already exited|no background shell/)
    end
  end

  describe "action: kill" do
    it "terminates a running background shell" do
      start = shell.call(
        "command" => "for i in 1 2 3 4 5; do echo step$i; sleep 0.2; done",
        "run_in_background" => true
      )
      run_id = start[/bg_\h+/]
      sleep 0.3

      killed = manage.call("run_id" => run_id, "action" => "kill")
      expect(killed).to include("terminated")

      # RETIRED, not dropped (#78): still retrievable with a terminal status.
      after = payload(output(run_id, mode: "all"))
      expect(after).not_to include("no background shell")
      expect(after).to match(/status=(failed|completed)/)
    end

    it "reports already-exited for a shell that finished on its own" do
      start  = shell.call("command" => "echo bye", "run_in_background" => true)
      run_id = start[/bg_\h+/]

      50.times do
        entry = registry.find(run_id)
        break if entry.nil? || registry.status(entry) != :running

        sleep 0.05
      end

      res = manage.call("run_id" => run_id, "action" => "kill")
      expect(res).to match(/already exited|no background shell/)
    end
  end

  # The merged tool must reproduce the four tools' approval EXACTLY: output/tail/
  # wait are :low (unprompted); input/kill are :medium (gated). ApprovalPolicy owns
  # the per-action branch (a single static tool risk can't express the split).
  describe "per-action approval (Security::ApprovalPolicy)" do
    let(:policy) do
      Rubino::Security::ApprovalPolicy.new(
        config: test_configuration("approvals" => { "mode" => "manual" })
      )
    end

    before { Rubino::Modes.set(:default) }

    it "runs the read-only observation actions unprompted" do
      expect(policy.decide(manage, arguments: { "action" => "output", "run_id" => "bg_x" })).to eq(:allow)
      expect(policy.decide(manage, arguments: { "action" => "tail", "run_id" => "bg_x" })).to eq(:allow)
      expect(policy.decide(manage, arguments: { "action" => "wait", "run_id" => "bg_x" })).to eq(:allow)
    end

    it "gates the mutating actions like the medium-risk shell_input/shell_kill did" do
      expect(policy.decide(manage, arguments: { "action" => "input", "run_id" => "bg_x", "input" => "y" })).to eq(:ask)
      expect(policy.decide(manage, arguments: { "action" => "kill", "run_id" => "bg_x" })).to eq(:ask)
    end
  end
end
