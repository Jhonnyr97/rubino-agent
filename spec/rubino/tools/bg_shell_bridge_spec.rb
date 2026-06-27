# frozen_string_literal: true

# Slice 1: a background SHELL gets the same dev UX as a subagent — it appears in
# the live set the picker/cards read (BackgroundTasks#running) and is stoppable
# through the shared stop path — via a read-time ShellEntryAdapter, with NO second
# registry entry (so no status-sync / double-notice / concurrency-cap coupling).
RSpec.describe "background shell ↔ BackgroundTasks bridge" do # rubocop:disable RSpec/DescribeClass
  let(:bg) { Rubino::Tools::BackgroundTasks.instance }
  let(:shells) { Rubino::Tools::ShellRegistry.instance }

  after do
    shells.reset! if shells.respond_to?(:reset!)
    bg.reset! if bg.respond_to?(:reset!)
  end

  def wait_until(timeout: 5.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return true if yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  it "shows a running shell in BackgroundTasks#running with subagent='shell'" do
    entry = shells.spawn(command: %(sleep 5), cwd: "/tmp")
    row = bg.running.find { |e| e.id == entry.id }

    expect(row).not_to be_nil
    expect(row.subagent).to eq("shell") # the picker/card label reads "shell"
    expect(row.prompt).to eq("sleep 5") # card title = the command
    expect(row.status).to eq(:running)
    expect(row).to respond_to(:shell?)
  ensure
    shells.terminate(entry) if entry
  end

  it "does NOT pollute the subagent concurrency count (shell isn't a run)" do
    before = bg.send(:running_count)
    entry = shells.spawn(command: %(sleep 5), cwd: "/tmp")
    expect(bg.send(:running_count)).to eq(before) # running_count reads @entries only
  ensure
    shells.terminate(entry) if entry
  end

  it "stops a shell through the shared stop path (find → stop_entry)" do
    entry = shells.spawn(command: %(sleep 30), cwd: "/tmp")
    row = bg.find(entry.id)
    expect(row.shell?).to be(true)

    bg.stop_entry(row)
    expect(wait_until { !entry.wait_thr.alive? }).to be(true) # process group killed
    expect(bg.running.map(&:id)).not_to include(entry.id)     # dropped from the live set
  end

  it "renders a shell row through the real SubagentCards formatter without raising" do
    entry = shells.spawn(command: %(sleep 5), cwd: "/tmp")
    rows = bg.running
    cards = Rubino::UI::SubagentCards.new(pastel: Pastel.new)
    expect { cards.card_lines(rows) }.not_to raise_error
  ensure
    shells.terminate(entry) if entry
  end

  it "omits the meaningless 'N tools' card segment for a shell (no tools)" do
    entry = shells.spawn(command: %(sleep 5), cwd: "/tmp")
    row  = bg.running.find { |e| e.id == entry.id }
    line = Rubino::UI::SubagentCards.new(pastel: Pastel.new).card_line(row)
    expect(line).to include("sleep 5")
    expect(line).not_to include("tool") # subagents show "N tools"; a shell must not
  ensure
    shells.terminate(entry) if entry
  end

  it "reports a UI-stopped shell as :stopped, not :failed" do
    entry = shells.spawn(command: %(sleep 30), cwd: "/tmp")
    shells.terminate(entry)
    expect(wait_until { !entry.wait_thr.alive? }).to be(true)
    expect(shells.status(entry)).to eq(:stopped) # a deliberate stop, not a crash
  end

  it "includes the shell in #list (so /status count + /agents list show it)" do
    entry = shells.spawn(command: %(sleep 5), cwd: "/tmp")
    expect(bg.list.map(&:id)).to include(entry.id)
  ensure
    shells.terminate(entry) if entry
  end

  # Polymorphic steer: a shell has no turn to fold a note into — "steering" it
  # writes the text to its stdin (the shell analogue), via the SAME /agents steer
  # path subagents use.
  it "routes steer to the shell's stdin (not a steer_queue)" do
    entry = shells.spawn(command: %(read X; echo "steered=$X"), cwd: "/tmp")
    expect(bg.steer(entry.id, "PONG")).to be(true)
    expect(wait_until { shells.read_all(entry).include?("steered=PONG") }).to be(true)
  ensure
    shells.terminate(entry) if entry
  end

  # Polymorphic peek: a shell's "probe" is an instant output snapshot — NO LLM
  # round-trip (the bug the adversarial pass caught).
  it "answers a probe/peek with the shell's output and no model call" do
    entry = shells.spawn(command: %(echo PROBE_ME; sleep 5), cwd: "/tmp")
    wait_until { shells.read_all(entry).include?("PROBE_ME") }
    row = bg.find(entry.id)
    expect(row.peek("anything")).to include("PROBE_ME")
  ensure
    shells.terminate(entry) if entry
  end
end
