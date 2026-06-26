# frozen_string_literal: true

require "stringio"

# Parent-death deadlock fix — the CALL-SITE wiring. BackgroundTasks#cancel_all
# is the structured-concurrency teardown seam; these specs pin that the
# parent-death edges in ChatCommand do the right teardown (the behavior that the
# child unwinds rather than parking ~900s is proven in
# background_tasks_parent_death_spec.rb):
#   * the HUP/TERM external-teardown trap (install_session_end_traps) reaps the
#     child shell groups via ShellRegistry#kill_all_groups BEFORE exit(0), and
#     stays TRAP-SAFE — it does NOT route through #cancel_all, whose #running /
#     #stop_entry / pre-fix #kill_all_groups all take a Mutex (forbidden in a
#     trap → ThreadError, which used to kill the whole trap and orphan the
#     shells, #478);
#   * the /agent switch (switch_primary_agent) — non-destructive, so it keeps the
#     registry alive rather than cancelling running children.
RSpec.describe Rubino::CLI::ChatCommand do
  subject(:cmd) { described_class.new("query" => "hi") }

  let(:registry) { instance_double(Rubino::Tools::BackgroundTasks) }

  before do
    allow(Rubino::Tools::BackgroundTasks).to receive(:instance).and_return(registry)
  end

  describe "HUP/TERM external-teardown trap (install_session_end_traps)" do
    let(:runner)    { instance_double(Rubino::Agent::Runner) }
    let(:shell_reg) { instance_double(Rubino::Tools::ShellRegistry) }

    before do
      allow(runner).to receive(:cancel!)
      allow(runner).to receive(:end_session!)
      allow(Rubino::Tools::ShellRegistry).to receive(:instance).and_return(shell_reg)
      allow(shell_reg).to receive(:kill_all_groups)
      # cancel_all MUST NOT be reached from the trap (its Mutex#synchronize is
      # forbidden in trap context). Allow it only so we can assert it is NOT
      # called — a real call would also raise ThreadError under a real signal.
      allow(registry).to receive(:cancel_all)
    end

    it "reaps the child shell groups BEFORE exit(0), trap-safely (no #cancel_all, no Mutex)" do
      skip "no SIGTERM on this platform" unless Signal.list.key?("TERM")

      # Arm the traps, then pull back the handler the trap installed (re-trapping
      # returns the current handler) WITHOUT firing a real signal. The handler
      # ends in exit(0), so invoking it directly raises SystemExit.
      saved = Signal.trap("TERM", "DEFAULT")
      begin
        cmd.send(:install_session_end_traps, runner)
        handler = Signal.trap("TERM", "DEFAULT")
        expect(handler).to respond_to(:call)

        expect { handler.call("TERM") }.to raise_error(SystemExit)
        # The shell groups are reaped via the lock-free trap-safe path...
        expect(shell_reg).to have_received(:kill_all_groups)
        expect(runner).to have_received(:cancel!).with(reason: :external)
        expect(runner).to have_received(:end_session!)
        # ...NOT through #cancel_all (which takes a Mutex → ThreadError in a trap,
        # the root cause of #478).
        expect(registry).not_to have_received(:cancel_all)
      ensure
        Signal.trap("TERM", saved || "DEFAULT")
      end
    end
  end

  describe "/agent switch (switch_primary_agent) — non-destructive" do
    let(:runner) { instance_double(Rubino::Agent::Runner) }
    let(:ui)     { Rubino::UI::Null.new }

    before do
      allow(runner).to receive(:agent_definition=)
      allow(Rubino::ActiveAgent).to receive(:set)
      allow(Rubino::ActiveAgent).to receive_messages(current: "explore", definition: nil)
    end

    it "does NOT cancel children (a switch keeps the registry alive)" do
      allow(registry).to receive(:running).and_return([])
      allow(registry).to receive(:cancel_all) # allowed so we can assert it is NOT called
      allow(ui).to receive(:success)

      cmd.send(:switch_primary_agent, "general", runner, ui)

      expect(registry).not_to have_received(:cancel_all)
      expect(ui).to have_received(:success).with(a_string_matching(/explore → /))
    end
  end
end
