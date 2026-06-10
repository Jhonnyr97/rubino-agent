# frozen_string_literal: true

# The interactive prompt is agent-composer style — `default ❯ ` — not shell.
# Mode is the only live context shown; workspace, git, model, and session
# are printed once at startup in run_interactive. The chip name matches the
# canonical mode label used by /mode and the transition banner (F9).
RSpec.describe Rubino::CLI::ChatCommand do
  subject(:cmd) { described_class.new({}) }

  describe "#build_prompt" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    def strip_ansi(s) = s.gsub(/\e\[[0-9;]*m/, "")

    it "[default] prompt in default mode" do
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("default ❯ ")
    end

    it "[plan] prompt in :plan" do
      Rubino::Modes.set(:plan)
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("plan ❯ ")
    ensure
      Rubino::Modes.set(:default)
    end

    it "[yolo] prompt in :yolo" do
      Rubino::Modes.set(:yolo)
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("yolo ❯ ")
    ensure
      Rubino::Modes.set(:default)
    end

    it "no git context in prompt (it's in the startup banner)" do
      Rubino::Modes.set(:yolo)
      system("git init -q -b main && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init")
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("yolo ❯ ")
    end

    it "appends a dim (skill: <name>) segment when a skill is active" do
      Rubino::ActiveSkill.set("ruby-expert")
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("default (skill: ruby-expert) ❯ ")
    ensure
      Rubino::ActiveSkill.reset!
    end

    it "drops the skill segment when no skill is active" do
      Rubino::ActiveSkill.reset!
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("default ❯ ")
    end

    it "composes the skill segment alongside a non-default mode" do
      Rubino::Modes.set(:yolo)
      Rubino::ActiveSkill.set("react-pro")
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("yolo (skill: react-pro) ❯ ")
    ensure
      Rubino::Modes.set(:default)
      Rubino::ActiveSkill.reset!
    end

    it "colours :default dim, :plan cyan, :yolo bold yellow" do
      pastel = Pastel.new(enabled: true)
      cmd.instance_variable_set(:@pastel, pastel)

      # Check that mode_label produces the right colors
      Rubino::Modes.set(:default)
      default_label = cmd.send(:mode_label)
      expect(default_label).to eq(pastel.dim("default"))

      Rubino::Modes.set(:plan)
      plan_label = cmd.send(:mode_label)
      expect(plan_label).to eq(pastel.cyan("plan"))

      Rubino::Modes.set(:yolo)
      yolo_label = cmd.send(:mode_label)
      expect(yolo_label).to eq(pastel.yellow.bold("yolo"))
    ensure
      Rubino::Modes.set(:default)
    end
  end

  describe "#cycle_mode (Shift+Tab)" do
    def strip_ansi(s) = s.gsub(/\e\[[0-9;]*m/, "")

    # Marks the yolo two-step (#152) as armed at a deliberate-beat distance in
    # the past, so the NEXT cycle_mode press counts as the explicit confirm.
    def arm_yolo_confirm(seconds_ago: 1.0)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cmd.instance_variable_set(:@yolo_armed_at, now - seconds_ago)
    end

    it "cycles default→plan→yolo→default, with yolo behind a confirm press (#152)" do
      Rubino::Modes.set(:default)
      cmd.send(:cycle_mode)
      expect(Rubino::Modes.current).to eq(:plan)
      cmd.send(:cycle_mode) # lands on yolo → ARMS, does not switch
      expect(Rubino::Modes.current).to eq(:plan)
      arm_yolo_confirm
      cmd.send(:cycle_mode) # deliberate second press confirms
      expect(Rubino::Modes.current).to eq(:yolo)
      cmd.send(:cycle_mode)
      expect(Rubino::Modes.current).to eq(:default)
    ensure
      Rubino::Modes.set(:default)
    end

    it "returns the freshly-built prompt chip and prints the transition footer" do
      Rubino::Modes.set(:default)
      out = capture_stdout { @new_prompt = cmd.send(:cycle_mode) }
      expect(strip_ansi(@new_prompt)).to eq("plan ❯ ")
      # Same `<old> → <new>` arrow grammar as the /mode footer (#78).
      expect(strip_ansi(out))
        .to include("┄ mode default → plan — #{Rubino::Modes.description(:plan)}, shift+tab to cycle ┄")
    ensure
      Rubino::Modes.set(:default)
    end

    # #152: blind Shift+Tab mashing used to land on "approvals skipped" with
    # only a dim banner — and the gates of RUNNING background children dropped
    # the same instant. The press that lands on yolo now only ARMS it.
    describe "yolo two-step confirm (#152)" do
      before { Rubino::Modes.set(:plan) }

      after { Rubino::Modes.set(:default) }

      it "the press that reaches yolo arms + announces instead of switching" do
        out = capture_stdout { @prompt = cmd.send(:cycle_mode) }
        expect(Rubino::Modes.current).to eq(:plan) # unchanged
        expect(strip_ansi(@prompt)).to eq("plan ❯ ") # chip unchanged too
        expect(strip_ansi(out)).to include("yolo skips ALL approvals")
        expect(strip_ansi(out)).to include("press shift+tab again to confirm")
      end

      it "a deliberate second press (after the minimum beat) confirms yolo" do
        capture_stdout { cmd.send(:cycle_mode) } # arm
        arm_yolo_confirm(seconds_ago: 1.0)
        out = capture_stdout { cmd.send(:cycle_mode) }
        expect(Rubino::Modes.current).to eq(:yolo)
        expect(strip_ansi(out)).to include("mode plan → yolo")
      end

      it "a blind mash (presses faster than the minimum beat) keeps re-arming, never confirms" do
        5.times { capture_stdout { cmd.send(:cycle_mode) } } # ~0s apart
        expect(Rubino::Modes.current).to eq(:plan)
      end

      it "a stale arm (window expired) re-arms instead of confirming" do
        capture_stdout { cmd.send(:cycle_mode) } # arm
        arm_yolo_confirm(seconds_ago: 60.0)      # way past the window
        out = capture_stdout { cmd.send(:cycle_mode) }
        expect(Rubino::Modes.current).to eq(:plan)
        expect(strip_ansi(out)).to include("press shift+tab again to confirm")
      end

      it "the confirm toast counts live background children whose gates would drop" do
        Rubino::Tools::BackgroundTasks.instance.reserve(subagent: "explore", prompt: "x")
        out = capture_stdout { cmd.send(:cycle_mode) }
        expect(strip_ansi(out)).to include("1 running subagent(s) will run gated actions unprompted")
      ensure
        Rubino::Tools::BackgroundTasks.reset!
      end
    end

    # D2/D3: with a live composer the confirmation is a TRANSIENT toast routed
    # through composer#announce (live region, never committed), NOT print_above.
    # So cycling N times never stacks scrollback banners — each press just
    # REPLACES the transient line; only the prompt chip reflects the mode.
    it "shows the confirmation via the composer's transient #announce (no committed scrollback)" do
      Rubino::Modes.set(:default)
      composer = instance_double(Rubino::UI::BottomComposer)
      allow(Rubino::UI::BottomComposer).to receive(:current).and_return(composer)
      announced = []
      allow(composer).to receive(:announce) { |s| announced << s }
      # If the implementation ever regressed to committing the banner, this would
      # catch it: print_above must NOT be used for the mode confirmation.
      allow(composer).to receive(:print_above) { raise "mode banner must not be committed via print_above" }

      cmd.send(:cycle_mode) # → plan
      cmd.send(:cycle_mode) # → yolo arm toast (#152: a transient announce too)
      expect(strip_ansi(announced.last)).to include("press shift+tab again to confirm")
      expect(announced.size).to eq(2) # one transient toast per press, replaced not stacked
    ensure
      Rubino::Modes.set(:default)
    end
  end

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end
end
