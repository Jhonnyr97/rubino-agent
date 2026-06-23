# frozen_string_literal: true

# #78 — a SHORT backgrounded command (`shell run_in_background: true` with e.g.
# "sleep 0; echo X") finishes before the next turn. Before this fix, the first
# reader that observed it non-running DROPPED it from the registry, which also
# collapsed `ShellRegistry#any?` to false — so the shell-management tools
# vanished from the schema next turn and the model could never fetch the
# captured output it was told to read. A finished entry is now RETIRED: its
# buffer + exit status stay retrievable and `any?` keeps the tools exposed,
# bounded by RETIRED_TTL / MAX_RETIRED.
RSpec.describe "Completed background shell output stays reachable (#78)" do # rubocop:disable RSpec/DescribeClass
  let(:shell)        { Rubino::Tools::ShellTool.new }
  let(:shell_output) { Rubino::Tools::ShellOutputTool.new }
  let(:registry)     { Rubino::Tools::ShellRegistry.instance }

  before { Rubino::Tools::ShellRegistry.reset! }
  after  { Rubino::Tools::ShellRegistry.reset! }

  def wait_finished(run_id)
    30.times do
      entry = registry.find(run_id)
      break if entry && registry.status(entry) != :running

      sleep 0.05
    end
  end

  it "keeps a completed bg shell's output retrievable on the NEXT turn, with exit status" do
    start  = shell.call("command" => "echo short_bg_out", "run_in_background" => true)
    run_id = start[/bg_\h+/]
    wait_finished(run_id)

    # TURN 1: read the output. The shell is already finished — the entry is
    # retired here (not dropped), so it remains retrievable.
    first = shell_output.call("run_id" => run_id, "mode" => "all")
    expect(first).to include("short_bg_out")
    expect(first).to match(/status=(completed|failed) exit=\d+/)

    # TURN 2 (next turn): the model can STILL fetch the captured output + exit
    # status — pre-fix this errored "no background shell" because the entry was
    # dropped the moment turn 1 saw it non-running.
    second = shell_output.call("run_id" => run_id, "mode" => "all")
    expect(second).not_to include("no background shell")
    expect(second).to include("short_bg_out")
    expect(second).to match(/status=(completed|failed) exit=\d+/)
  end

  it "keeps shell_output exposed in the situational gate after a completed bg shell is read" do
    Rubino.loader.eager_load
    Rubino::Tools::Registry.register_defaults!

    start  = shell.call("command" => "echo gate_probe", "run_in_background" => true)
    run_id = start[/bg_\h+/]
    wait_finished(run_id)

    # Reading the finished shell once is what USED to drop it from the registry
    # (pre-fix `registry.remove`), collapsing `any?` to false and hiding the
    # shell-management tools next turn. Now the read RETIRES it, so it lingers.
    shell_output.call("run_id" => run_id, "mode" => "all")

    # `any?` must stay true so shell_output remains in the schema next turn,
    # letting the model fetch the output again. Pre-fix this was false here.
    expect(registry.any?).to be(true)
    names = Rubino::Tools::Registry.enabled_tools.map(&:name)
    expect(names).to include("shell_output")
  end

  it "bounds the retained-completed set (TTL + MAX_RETIRED) so the registry never grows unbounded" do
    reg = Rubino::Tools::ShellRegistry.new
    ids = Array.new(Rubino::Tools::ShellRegistry::MAX_RETIRED + 5) do
      entry = reg.spawn(command: "true", cwd: Dir.pwd)
      entry.wait_thr.join
      reg.retire(entry.id)
      entry.id
    end

    live = reg.instance_variable_get(:@entries)
    expect(live.size).to be <= Rubino::Tools::ShellRegistry::MAX_RETIRED
    # Oldest-retired are evicted first; the most recent retires survive.
    expect(live).to have_key(ids.last)
    expect(live).not_to have_key(ids.first)
  end

  it "reaps a retired entry once its TTL has elapsed (gate then closes)" do
    reg   = Rubino::Tools::ShellRegistry.new
    entry = reg.spawn(command: "echo ttl", cwd: Dir.pwd)
    entry.wait_thr.join
    reg.retire(entry.id)
    expect(reg.any?).to be(true)

    # Fast-forward past the TTL without sleeping the test.
    entry.retired_at = Time.now - Rubino::Tools::ShellRegistry::RETIRED_TTL - 1
    expect(reg.any?).to be(false)
    expect(reg.find(entry.id)).to be_nil
  end
end
