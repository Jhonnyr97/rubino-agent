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
                    steer_agent: nil, probe_agent: nil)
  end
  let(:entry) do
    instance_double(Rubino::Tools::BackgroundTasks::Entry,
                    id: "sa_1", subagent: "explore", status: :running, messages: [],
                    shell?: false, runner: nil)
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
    it "marks attached and replays the agent's OWN transcript with banner:false" do
      expect(cmd.send(:session_resolver)).to receive(:replay_messages)
        .with(ui, [], banner: false)
      attach!
      expect(cmd.send(:attached_to_agent?)).to be(true)
    end

    it "is a no-op (error) when the agent is already gone" do
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:find).with("ghost").and_return(nil)
      cmd.send(:attach_agent_view, "ghost", ui)
      expect(cmd.send(:attached_to_agent?)).to be(false)
    end

    # FIX B — focal-switch-replay: after replaying the completed-history
    # transcript, the entering subagent's in-progress live state is repainted
    # so the focused view shows the current operation (streaming reasoning,
    # answer prose, open tool row) rather than a frozen empty tail.
    it "calls repaint_in_progress on the sub CLI after replay" do
      sub_cli = instance_double(Rubino::UI::CLI, repaint_in_progress: nil)
      sub_runner = instance_double(Rubino::Agent::Runner, ui: sub_cli)
      entry_with_runner = instance_double(
        Rubino::Tools::BackgroundTasks::Entry,
        id: "sa_1", subagent: "explore", status: :running,
        messages: [], shell?: false, runner: sub_runner
      )
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:find)
        .with("sa_1").and_return(entry_with_runner)
      allow(cmd.send(:session_resolver)).to receive(:replay_messages)

      cmd.send(:attach_agent_view, "sa_1", ui)

      expect(sub_cli).to have_received(:repaint_in_progress)
    end

    it "does not crash (no-op) when the entry has no runner (sync/foreground)" do
      entry_no_runner = instance_double(
        Rubino::Tools::BackgroundTasks::Entry,
        id: "sa_no", subagent: "explore", status: :running,
        messages: [], shell?: false, runner: nil
      )
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:find)
        .with("sa_no").and_return(entry_no_runner)
      allow(cmd.send(:session_resolver)).to receive(:replay_messages)

      expect { cmd.send(:attach_agent_view, "sa_no", ui) }.not_to raise_error
    end
  end

  # #82: the "polishing memory…" indicator belongs to the MAIN session; while
  # attached it must NOT bleed into the focused sub view. It rides #set_status
  # (the status bar, NOT behind the main-render gate), so it is suppressed at
  # the source in the idle loop.
  describe "#update_polishing_indicator while attached" do
    let(:composer) { instance_spy(Rubino::UI::BottomComposer) }

    before do
      allow(composer).to receive(:respond_to?).with(:set_status).and_return(true)
      allow(cmd).to receive(:polishing_status_line).and_return("polishing…")
      allow(cmd).to receive(:build_status_line).and_return("status")
    end

    it "does NOT paint the polishing status while attached, even when polishing" do
      allow(runner).to receive(:polishing?).and_return(true)
      attach!
      cmd.send(:update_polishing_indicator, composer, runner, false)
      expect(composer).not_to have_received(:set_status)
    end

    it "still paints the polishing status when NOT attached (no regression)" do
      allow(runner).to receive(:polishing?).and_return(true)
      cmd.send(:update_polishing_indicator, composer, runner, false)
      expect(composer).to have_received(:set_status)
    end
  end

  # S7 F2 — the polish worker runs for >1min after almost every turn; its
  # indicator must NOT occlude the `ctx ~Xk/128k (Y%)` saturation bar at idle.
  # The indicator is composed ALONGSIDE the normal status bar, not in place of it.
  describe "#polishing_status_line composition (F2)" do
    it "renders the polishing indicator ALONGSIDE the ctx status bar" do
      allow(cmd).to receive(:build_status_line)
        .with(runner).and_return(" default · gpt-4.1 · ctx ~8.4k/128k (7%)")

      line = cmd.send(:polishing_status_line, runner)

      expect(line).to include("polishing memory… (Esc to skip)")
      # The ctx saturation stays visible — not occluded by the indicator.
      expect(line).to include("ctx ~8.4k/128k (7%)")
    end

    it "falls back to the bare indicator when there is no status bar" do
      allow(cmd).to receive(:build_status_line).with(runner).and_return(nil)

      line = cmd.send(:polishing_status_line, runner)

      expect(line).to include("polishing memory… (Esc to skip)")
      expect(line).not_to include("ctx ")
    end
  end

  # Focus-gating (tmux-style unified render): attach/detach set the composer's
  # FOCUSED agent so only the focused agent's frames paint. A still-running parent
  # turn keeps streaming to its session (origin :main) but DROPS while a sub is
  # focused; the sub's OWN per-sub CLI paints live through its origin; the replay
  # is exempt so the focused view paints. A StringIO composer stands in for the
  # live one.
  describe "focus-gating wiring (composer focus + per-origin paint)" do
    let(:out) { StringIO.new }
    let(:composer) do
      Rubino::UI::BottomComposer.new(
        input_queue: Rubino::Interaction::InputQueue.new,
        input: StringIO.new, output: out
      )
    end

    around do |ex|
      prev = Rubino::UI::BottomComposer.current
      Rubino::UI::BottomComposer.current = composer
      ex.run
    ensure
      Rubino::UI::BottomComposer.current = prev
    end

    it "attach FOCUSES the composer on the sub and replays it through the exempt seam" do
      expect(composer).to receive(:with_replay_exempt).and_yield
      attach!
      expect(composer.focused_agent_id).to eq("sa_1")
      expect(composer.main_render_suppressed?).to be(true)
    end

    it "detach REFOCUSES :main after replaying the main view" do
      allow(cmd.send(:session_resolver)).to receive(:replay_session)
      attach!
      expect(composer.focused_agent_id).to eq("sa_1")
      cmd.send(:detach_agent_view, runner, ui)
      expect(composer.focused_agent_id).to eq(:main)
    end

    # The core of the unified render: a sub-CLI frame (its own UI::CLI tagged with
    # the entry id) PAINTS when that sub is focused and is DROPPED when it isn't —
    # exactly the origin-gate behavior. Drive the sub's CLI directly through one of
    # its commit seams (stream → committed prose / tool_started → committed row).
    describe "a sub-CLI's frames paint only while that sub is focused" do
      let(:sub_cli) { Rubino::UI::CLI.new(agent_id: "sa_1") }

      it "PAINTS the focused sub's committed line and DROPS the parent's (origin :main)" do
        attach! # focus → sa_1
        out.truncate(0)
        out.rewind

        # The still-running parent turn commits with origin :main → dropped.
        composer.print_above("parent turn line", origin: :main)
        # The focused sub commits its own row via its per-sub CLI → painted.
        sub_cli.send(:commit_async_above, ["⟂ explore · grep needle"])

        plain = out.string.gsub(/\e\[[0-9;]*m/, "")
        expect(plain).not_to include("parent turn line")
        expect(plain).to include("⟂ explore · grep needle")
      end

      it "DROPS the same sub-CLI frame once detached back to main" do
        allow(cmd.send(:session_resolver)).to receive(:replay_session)
        attach!
        cmd.send(:detach_agent_view, runner, ui)
        out.truncate(0)
        out.rewind

        # Focus is back on :main; the sub's frame (origin sa_1) now drops.
        sub_cli.send(:commit_async_above, ["⟂ explore · late frame"])
        expect(out.string.gsub(/\e\[[0-9;]*m/, "")).not_to include("late frame")
      end
    end

    # #37: while ATTACHED the parent's idle subagent cards belong to the main
    # view — they must NOT render under the focused sub-view. They reappear once
    # detached.
    it "suppresses the parent's subagent cards while attached, restoring them on detach" do
      allow(cmd.send(:session_resolver)).to receive(:replay_session)
      composer.set_cards(["• explore — searching"])
      expect(composer.send(:below_input_rows)).not_to be_empty

      attach!
      expect(composer.send(:below_input_rows)).to be_empty

      cmd.send(:detach_agent_view, runner, ui)
      composer.set_cards(["• explore — searching"])
      expect(composer.send(:below_input_rows)).not_to be_empty
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
                              id: "sa_2", subagent: "build", status: :running, messages: [],
                              shell?: false, runner: nil)
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

    it "STEERS a child parked on an approval with the raw plain text (folded in on resume)" do
      allow(entry).to receive(:status).and_return(:needs_approval)
      cmd.send(:handle_attached_input, "use postgres", runner, ui, cmd_executor)
      expect(agents_handler).to have_received(:steer_agent).with("sa_1", "use postgres")
    end

    it "/stop cancels the agent" do
      cmd.send(:handle_attached_input, "/stop", runner, ui, cmd_executor)
      expect(cmd_executor).to have_received(:try_execute).with("/agents sa_1 --stop")
    end

    # R3: `/stop <id>` (the EXACT syntax the footer advertises) typed while
    # attached must EXECUTE the command — not be swallowed as a steer note.
    it "DISPATCHES `/stop <id>` as a command (R3 — not steer)" do
      cmd.send(:handle_attached_input, "/stop sa_1", runner, ui, cmd_executor)
      expect(cmd_executor).to have_received(:try_execute).with("/stop sa_1")
      expect(agents_handler).not_to have_received(:steer_agent)
    end

    it "DISPATCHES other slash commands (`/agents`, `/status`) instead of steering them" do
      cmd.send(:handle_attached_input, "/agents", runner, ui, cmd_executor)
      cmd.send(:handle_attached_input, "/status", runner, ui, cmd_executor)
      expect(cmd_executor).to have_received(:try_execute).with("/agents")
      expect(cmd_executor).to have_received(:try_execute).with("/status")
      expect(agents_handler).not_to have_received(:steer_agent)
    end

    it "acts on a {attach_agent:} signal returned by a dispatched command" do
      other = instance_double(Rubino::Tools::BackgroundTasks::Entry,
                              id: "sa_9", subagent: "build", status: :running, messages: [],
                              shell?: false, runner: nil)
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:find).with("sa_9").and_return(other)
      allow(cmd_executor).to receive(:try_execute).with("/agents sa_9 --attach")
                                                  .and_return({ attach_agent: "sa_9" })
      cmd.send(:handle_attached_input, "/agents sa_9 --attach", runner, ui, cmd_executor)
      expect(cmd.instance_variable_get(:@attached_id)).to eq("sa_9")
    end

    it "still STEERS a plain (non-slash) running line (unchanged)" do
      cmd.send(:handle_attached_input, "look at the parser", runner, ui, cmd_executor)
      expect(agents_handler).to have_received(:steer_agent).with("sa_1", "look at the parser")
      expect(cmd_executor).not_to have_received(:try_execute)
    end

    # Y3 fold-in: `/back` (and `/detach`) detach to main regardless of draft —
    # the key-independent way out when ← is eaten as cursor-left.
    it "/back detaches to main" do
      expect(cmd.send(:session_resolver)).to receive(:replay_session).with(ui, "main-sess")
      cmd.send(:handle_attached_input, "/back", runner, ui, cmd_executor)
      expect(cmd.send(:attached_to_agent?)).to be(false)
    end

    it "/detach detaches to main" do
      allow(cmd.send(:session_resolver)).to receive(:replay_session)
      cmd.send(:handle_attached_input, "/detach", runner, ui, cmd_executor)
      expect(cmd.send(:attached_to_agent?)).to be(false)
    end

    # R3 also holds when the attached sub has FINISHED: a `/`-command still runs
    # (e.g. /stop another sub), only plain text gets the "has finished" notice.
    it "dispatches a slash command even when the attached child has finished" do
      allow(entry).to receive(:status).and_return(:completed)
      cmd.send(:handle_attached_input, "/status", runner, ui, cmd_executor)
      expect(cmd_executor).to have_received(:try_execute).with("/status")
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
                              id: "sa_2", subagent: "build", status: :running, messages: [],
                              shell?: false, runner: nil)
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:find).with("sa_2").and_return(other)
      cmd.send(:handle_attached_input, "/agents sa_2 --attach", runner, ui, cmd_executor)
      expect(cmd.instance_variable_get(:@attached_id)).to eq("sa_2")
    end
  end
end
