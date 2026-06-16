# frozen_string_literal: true

require "stringio"

# Parent-death deadlock fix — the CALL-SITE wiring. BackgroundTasks#cancel_all
# is the structured-concurrency teardown seam; these specs pin that the
# parent-death edges in ChatCommand actually invoke it (the behavior that the
# child unwinds rather than parking ~900s is proven in
# background_tasks_parent_death_spec.rb):
#   * the HUP/TERM external-teardown trap (install_session_end_traps), BEFORE
#     exit(0) and trap-safe;
#   * the /agent switch (switch_primary_agent) — non-destructive, so it SURFACES
#     a blocked child rather than cancelling it.
RSpec.describe Rubino::CLI::ChatCommand do
  subject(:cmd) { described_class.new("query" => "hi") }

  let(:registry) { instance_double(Rubino::Tools::BackgroundTasks) }

  before do
    allow(Rubino::Tools::BackgroundTasks).to receive(:instance).and_return(registry)
  end

  describe "HUP/TERM external-teardown trap (install_session_end_traps)" do
    let(:runner) { instance_double(Rubino::Agent::Runner) }

    before do
      allow(runner).to receive(:cancel!)
      allow(runner).to receive(:end_session!)
      allow(registry).to receive(:cancel_all)
    end

    it "cancels all live subagents BEFORE exit(0), so a blocked child unwinds on teardown" do
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
        expect(registry).to have_received(:cancel_all)
        expect(runner).to have_received(:cancel!).with(reason: :external)
      ensure
        Signal.trap("TERM", saved || "DEFAULT")
      end
    end
  end

  describe "/agent switch (switch_primary_agent) — non-destructive, surfaces blocked children" do
    let(:runner) { instance_double(Rubino::Agent::Runner) }
    let(:ui)     { Rubino::UI::Null.new }

    before do
      allow(runner).to receive(:agent_definition=)
      allow(Rubino::ActiveAgent).to receive(:set)
      allow(Rubino::ActiveAgent).to receive_messages(current: "explore", definition: nil)
    end

    def blocked_entry(id)
      Rubino::Tools::BackgroundTasks::Entry.new(id: id, subagent: "explore", status: :blocked_on_human)
    end

    it "does NOT cancel children (a switch keeps the registry alive) but surfaces the blocked ones" do
      allow(registry).to receive(:running).and_return([blocked_entry("sa_1"), blocked_entry("sa_2")])
      allow(registry).to receive(:cancel_all) # allowed so we can assert it is NOT called
      allow(ui).to receive(:warning)
      allow(ui).to receive(:info)
      allow(ui).to receive(:success)

      cmd.send(:switch_primary_agent, "general", runner, ui)

      expect(registry).not_to have_received(:cancel_all)
      expect(ui).to have_received(:warning).with(a_string_matching(/waiting on an answer/))
      expect(ui).to have_received(:info).with(a_string_matching(/sa_1/))
      expect(ui).to have_received(:info).with(a_string_matching(/sa_2/))
    end

    it "stays quiet when no child is blocked" do
      allow(registry).to receive(:running).and_return([])
      allow(ui).to receive(:warning)
      allow(ui).to receive(:success)

      cmd.send(:switch_primary_agent, "general", runner, ui)
      expect(ui).not_to have_received(:warning)
    end
  end
end
