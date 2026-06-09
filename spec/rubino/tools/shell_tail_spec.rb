# frozen_string_literal: true

# shell_tail blocks until the next chunk of output arrives on a background
# shell, or the process exits, or the timeout elapses. Lets an agent "follow"
# a long-running job (CI run, build, watcher) without re-polling shell_output
# in a busy loop.
RSpec.describe Rubino::Tools::ShellTailTool do
  subject(:tool) { described_class.new }

  let(:shell) { Rubino::Tools::ShellTool.new }

  after do
    # Drain any background entries the test left in the registry so a
    # subsequent example doesn't observe stale state.
    Rubino::Tools::ShellRegistry.instance.instance_variable_get(:@entries)
                                .keys
                                .each { |id| Rubino::Tools::ShellRegistry.instance.remove(id) }
  end

  it "returns immediately when bytes are already buffered" do
    bg = shell.call("command" => "echo first; sleep 0.3; echo second",
                    "run_in_background" => true)
    run_id = bg[/run_id=(\S+)/, 1] || bg[/Started background shell (\S+)/, 1]
    expect(run_id).not_to be_nil

    sleep 0.1 # let the echo land in the buffer

    out = tool.call("run_id" => run_id, "timeout" => 5)
    expect(out[:output]).to include("first")
    expect(out[:metrics]).to match(/\d+B/)
  end

  it "blocks until the next chunk arrives" do
    bg = shell.call("command" => "sleep 0.4; echo late",
                    "run_in_background" => true)
    run_id = bg[/Started background shell (\S+)/, 1]

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out     = tool.call("run_id" => run_id, "timeout" => 5)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(out[:output]).to include("late")
    expect(elapsed).to be >= 0.3
  end

  it "returns 'no new output before deadline' when timeout fires" do
    bg = shell.call("command" => "sleep 3; echo never_seen",
                    "run_in_background" => true)
    run_id = bg[/Started background shell (\S+)/, 1]

    out = tool.call("run_id" => run_id, "timeout" => 1)
    expect(out[:output]).to include("no new output before deadline")
    expect(out[:output]).not_to include("never_seen")
  end

  it "returns immediately when the process has exited and there are no fresh bytes" do
    bg = shell.call("command" => "echo done", "run_in_background" => true)
    run_id = bg[/Started background shell (\S+)/, 1]

    sleep 0.3 # let it finish

    # First call drains the "done" output.
    tool.call("run_id" => run_id, "timeout" => 1)

    # Re-find the entry — first call removed it if status was non-running, so
    # this confirms removal semantics.
    second = tool.call("run_id" => run_id, "timeout" => 1)
    expect(second).to include("no background shell with run_id=")
  end

  it "returns an error for an unknown run_id" do
    out = tool.call("run_id" => "bg_doesnotexist", "timeout" => 1)
    expect(out).to include("no background shell with run_id=bg_doesnotexist")
  end

  it "requires run_id" do
    out = tool.call("run_id" => "")
    expect(out).to include("run_id is required")
  end
end
