# frozen_string_literal: true

# Rail rubino: the interactive prompt is a CONSTANT clean `❯ ` behind the red
# rail — the mode is NOT a prompt chip anymore. The mode token (with the
# branch / active-skill tokens) leads the STATUS BAR under the input (see
# UI::StatusBar), and Shift+Tab updates that bar LIVE by returning the
# freshly-built status line to the composer. The token names match the
# canonical mode labels used by /mode and the transition banner (F9).
RSpec.describe Rubino::CLI::ChatCommand do
  subject(:cmd) { described_class.new({}) }

  describe "#build_prompt (constant clean prompt)" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    def strip_ansi(s) = s.gsub(/\e\[[0-9;]*m/, "")

    it "is the bare ❯ in default mode" do
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("❯ ")
    end

    it "stays the bare ❯ in :plan and :yolo (mode rides the status bar)" do
      Rubino::Modes.set(:plan)
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("❯ ")
      Rubino::Modes.set(:yolo)
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("❯ ")
    ensure
      Rubino::Modes.set(:default)
    end

    it "no git context in prompt (it's in the startup banner)" do
      system("git init -q -b main && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init")
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("❯ ")
    end

    it "stays the bare ❯ with a skill active (the skill token rides the status bar)" do
      Rubino::ActiveSkill.set("ruby-expert")
      expect(strip_ansi(cmd.send(:build_prompt))).to eq("❯ ")
    ensure
      Rubino::ActiveSkill.reset!
    end

    it "the composer rail is the red ▍ (the ◆ brand accent), one column wide" do
      pastel = Pastel.new(enabled: true)
      cmd.instance_variable_set(:@pastel, pastel)
      expect(cmd.send(:composer_rail)).to eq(pastel.red("▍"))
    end
  end

  # The mode token in the status bar: dim default, plan yellow, yolo red —
  # the subtle accent that replaced the prompt chip's coloring.
  describe "status-bar mode token (UI::StatusBar.mode_segment)" do
    let(:pastel) { Pastel.new(enabled: true) }

    it "colours :default dim, :plan yellow, :yolo red" do
      expect(Rubino::UI::StatusBar.mode_segment(:default, pastel)).to eq(pastel.dim("default"))
      expect(Rubino::UI::StatusBar.mode_segment(:plan, pastel)).to eq(pastel.yellow("plan"))
      expect(Rubino::UI::StatusBar.mode_segment(:yolo, pastel)).to eq(pastel.red("yolo"))
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

    it "returns the freshly-built STATUS LINE (live statusbar update) and prints the transition footer" do
      Rubino::Modes.set(:default)
      runner = instance_double(Rubino::Agent::Runner)
      allow(cmd).to receive(:build_status_line).with(runner).and_return(" plan · m3 · ctx ~1k/64k")
      out = capture_stdout { @status = cmd.send(:cycle_mode, runner) }
      expect(@status).to eq(" plan · m3 · ctx ~1k/64k")
      # Same `<old> → <new>` arrow grammar as the /mode footer (#78).
      expect(strip_ansi(out))
        .to include("┄ mode default → plan — #{Rubino::Modes.description(:plan)}, shift+tab to cycle ┄")
    ensure
      Rubino::Modes.set(:default)
    end

    it "returns nil (no statusbar update) without a runner, but still cycles" do
      Rubino::Modes.set(:default)
      out = capture_stdout { @status = cmd.send(:cycle_mode) }
      expect(@status).to be_nil
      expect(Rubino::Modes.current).to eq(:plan)
      expect(strip_ansi(out)).to include("mode default → plan")
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
        out = capture_stdout { @status = cmd.send(:cycle_mode) }
        expect(Rubino::Modes.current).to eq(:plan) # unchanged
        expect(@status).to be_nil # mode unchanged ⇒ no statusbar repaint
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
      end
    end

    # D2/D3: with a live composer the confirmation is a TRANSIENT toast routed
    # through composer#announce (live region, never committed), NOT print_above.
    # So cycling N times never stacks scrollback banners — each press just
    # REPLACES the transient line; only the statusbar's mode token persists.
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
