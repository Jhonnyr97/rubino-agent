# frozen_string_literal: true

require "spec_helper"

# The Claude-style agent-attach view: selecting a subagent (the picker's Enter)
# switches the whole timeline to that agent's (clear + replay) and SCOPES the
# input to it — typed lines steer/answer the child instead of running a parent
# turn. These specs drive the REPL's attach seams directly (the live geometry is
# covered by the headless ttyd run, which StringIO specs can't see).
RSpec.describe Rubino::CLI::ChatCommand do
  let(:cmd) { described_class.new({}) }

  let(:ui)           { Rubino::UI::Null.new }
  let(:cmd_executor) { instance_double(Rubino::Commands::Executor) }
  let(:runner)       { instance_double(Rubino::Agent::Runner, session: { id: "main-sess" }) }
  let(:agents_handler) do
    instance_double(Rubino::Commands::Handlers::Agents,
                    steer_agent: nil, probe_agent: nil, deliver_reply: nil)
  end
  let(:entry) do
    instance_double(Rubino::Tools::BackgroundTasks::Entry,
                    id: "sa_1", subagent: "explore", status: :running, messages: [])
  end

  before do
    allow(Rubino::Tools::BackgroundTasks.instance).to receive(:find).with("sa_1").and_return(entry)
    allow(cmd).to receive(:clear_terminal) # never blast the test terminal
    allow(cmd).to receive(:agents_request_handler).and_return(agents_handler)
    allow(cmd_executor).to receive(:try_execute)
  end

  def attach!
    cmd.send(:attach_agent_view, "sa_1", ui)
  end

  describe "#build_prompt scope" do
    it "is the bare caret when not attached" do
      expect(cmd.send(:build_prompt)).to eq("❯ ")
    end

    it "is scoped to the agent id while attached" do
      attach!
      expect(cmd.send(:build_prompt)).to eq("sa_1 ❯ ")
    end
  end

  describe "#attach_agent_view" do
    it "marks attached and replays the agent's OWN transcript" do
      expect(cmd.send(:session_resolver)).to receive(:replay_messages).with(ui, [])
      attach!
      expect(cmd.send(:attached_to_agent?)).to be(true)
    end

    it "is a no-op (error) when the agent is already gone" do
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:find).with("ghost").and_return(nil)
      cmd.send(:attach_agent_view, "ghost", ui)
      expect(cmd.send(:attached_to_agent?)).to be(false)
    end
  end

  # Focus-gating (Slice 3): attach/detach drive the composer's main-render gate
  # so a still-running parent turn keeps streaming to its session but does NOT
  # paint the attached sub's view; the replay is exempt so the focused view
  # paints. A StringIO composer stands in for the live one.
  describe "focus-gating wiring (composer suppression)" do
    let(:composer) do
      Rubino::UI::BottomComposer.new(
        input_queue: Rubino::Interaction::InputQueue.new,
        input: StringIO.new, output: StringIO.new
      )
    end

    around do |ex|
      prev = Rubino::UI::BottomComposer.current
      Rubino::UI::BottomComposer.current = composer
      ex.run
    ensure
      Rubino::UI::BottomComposer.current = prev
    end

    it "attach SUPPRESSES main render, and replays the sub through the exempt seam" do
      expect(composer).to receive(:with_replay_exempt).and_yield
      attach!
      expect(composer.main_render_suppressed?).to be(true)
    end

    it "detach CLEARS the suppression after replaying the main view" do
      allow(cmd.send(:session_resolver)).to receive(:replay_session)
      attach!
      expect(composer.main_render_suppressed?).to be(true)
      cmd.send(:detach_agent_view, runner, ui)
      expect(composer.main_render_suppressed?).to be(false)
    end
  end

  # Mid-turn: the busy classifier (the reader-thread seam) is what routes input
  # while a parent turn owns the loop. Attach dispatches there now (no deferral),
  # and once attached EVERY typed line is scoped to the sub, never the parent.
  describe "#busy_command_handler while attached (mid-turn focus)" do
    let(:handler) { cmd.send(:busy_command_handler, runner) }

    it "dispatches a mid-turn --attach to the view switch (not a queue/toast)" do
      allow(cmd_executor).to receive(:try_execute) # not used: the real executor runs
      expect(cmd).to receive(:attach_agent_view).with("sa_1", anything)
      handler.call("/agents sa_1 --attach")
    end

    it "routes a plain line to the SUB (steer), returning :immediate so it never queues to the parent" do
      attach!
      expect(handler.call("look at the parser")).to eq(:immediate)
      expect(agents_handler).to have_received(:steer_agent).with("sa_1", "look at the parser")
    end

    it "detaches on /back while attached mid-turn" do
      attach!
      allow(cmd).to receive(:session_resolver).and_return(
        instance_double(Rubino::CLI::Chat::SessionResolver, replay_session: nil)
      )
      handler.call("/back")
      expect(cmd.send(:attached_to_agent?)).to be(false)
    end
  end

  describe "#handle_attached_input routing" do
    before { attach! }

    it "switches to ANOTHER agent when the picker re-attaches while attached" do
      other = instance_double(Rubino::Tools::BackgroundTasks::Entry,
                              id: "sa_2", subagent: "build", status: :running, messages: [])
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:find).with("sa_2").and_return(other)
      cmd.send(:handle_attached_input, "/agents sa_2 --attach", runner, ui, cmd_executor)
      expect(cmd.instance_variable_get(:@attached_id)).to eq("sa_2")
    end

    it "steers a RUNNING child with the RAW plain text (no command re-serialization)" do
      cmd.send(:handle_attached_input, 'make it say "hi"', runner, ui, cmd_executor)
      # Direct call keeps the embedded quotes intact — the old string round-trip
      # mangled them.
      expect(agents_handler).to have_received(:steer_agent).with("sa_1", 'make it say "hi"')
    end

    it "ANSWERS a blocked child with the raw plain text" do
      allow(entry).to receive(:status).and_return(:blocked_on_human)
      cmd.send(:handle_attached_input, "use postgres", runner, ui, cmd_executor)
      expect(agents_handler).to have_received(:deliver_reply).with(entry, "use postgres")
    end

    it "/stop cancels the agent" do
      cmd.send(:handle_attached_input, "/stop", runner, ui, cmd_executor)
      expect(cmd_executor).to have_received(:try_execute).with("/agents sa_1 --stop")
    end

    it "auto-detaches when the child is gone (never strands the user)" do
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:find).with("sa_1").and_return(nil)
      expect(cmd.send(:session_resolver)).to receive(:replay_session).with(ui, "main-sess")
      cmd.send(:handle_attached_input, "anything", runner, ui, cmd_executor)
      expect(cmd.send(:attached_to_agent?)).to be(false)
    end

    # The "forced to restart" report: a FINISHED child's entry still exists, so
    # the old code fell through to steer → "✗ cannot steer … (subagents reset
    # when rubino restarts)" and wedged the prompt on a dead scope.
    it "on a FINISHED child shows a calm notice and does NOT steer (no 'cannot steer / restart' wedge)" do
      allow(entry).to receive(:status).and_return(:completed)
      allow(ui).to receive(:info)
      cmd.send(:handle_attached_input, "keep going", runner, ui, cmd_executor)
      expect(agents_handler).not_to have_received(:steer_agent)
      expect(ui).to have_received(:info).with(a_string_including("has finished"))
    end

    it "still lets you SWITCH away from a finished child to another live one" do
      allow(entry).to receive(:status).and_return(:completed)
      other = instance_double(Rubino::Tools::BackgroundTasks::Entry,
                              id: "sa_2", subagent: "build", status: :running, messages: [])
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:find).with("sa_2").and_return(other)
      cmd.send(:handle_attached_input, "/agents sa_2 --attach", runner, ui, cmd_executor)
      expect(cmd.instance_variable_get(:@attached_id)).to eq("sa_2")
    end
  end
end
