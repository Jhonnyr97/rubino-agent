# frozen_string_literal: true

require "stringio"

# #169 — post-turn background work (the inline memory auto-extract / skill
# distill aux-LLM calls, a background subagent finishing at the idle prompt)
# must never paint over the bottom-composer prompt line or leave the `/` + `@`
# dropdowns dead. One invariant: while a composer is active, every transient
# ticker frame routes through the composer's own machinery (its render mutex),
# NEVER a raw `\r`/`\e[2K` repaint of the row the composer owns. The CR repaint
# stays ONLY for genuinely composer-less TTY contexts (the cooked /probe wait,
# #58; one-shot).
#
# These examples swap $stdout deliberately: the seam under test IS "which IO
# the ticker paints into", so output().to_stdout cannot express the assertions
# (stdout must stay EMPTY while the composer's own output receives the frames).
# rubocop:disable RSpec/ExpectOutput
RSpec.describe Rubino::UI::CLI do
  let(:queue)  { Rubino::Interaction::InputQueue.new }
  let(:output) { StringIO.new }

  # A TTY-shaped stdout WITHOUT a #live seam — exactly what $stdout looks like
  # when a composer is pinned but the StdoutProxy is not installed.
  def tty_stringio
    sio = StringIO.new
    def sio.tty? = true
    sio
  end

  after { Rubino::UI::BottomComposer.current = nil }

  describe "thinking ticker with an ACTIVE composer (no #live proxy)" do
    it "paints frames through the composer row and never CR-repaints the prompt line" do
      composer = Rubino::UI::BottomComposer.new(input_queue: queue, input: StringIO.new,
                                                output: output, prompt: "default ❯ ")
      Rubino::UI::BottomComposer.current = composer

      old = $stdout
      $stdout = tty_stringio
      begin
        ui = described_class.new
        ui.thinking_started
        sleep 0.35 # a few 0.1s frames
        ui.thinking_finished

        # No raw repaint reached the terminal the composer owns.
        expect($stdout.string).not_to include("\r\e[2K")
        expect($stdout.string).not_to include("thinking")
        # Frames went through the composer's transient row, and every frame
        # redrew the prompt line below it — the bottom line is never clobbered.
        expect(output.string).to include("thinking")
        last_frame = output.string.split("thinking").last
        expect(last_frame).to include("default ❯")
      ensure
        $stdout = old
      end
    end

    it "the / and @ dropdowns open while the ticker is running" do
      source = Rubino::UI::CompletionSource.new(commands: %w[/help /exit /memory])
      composer = Rubino::UI::BottomComposer.new(input_queue: queue, input: StringIO.new,
                                                output: output, completion_source: source)
      Rubino::UI::BottomComposer.current = composer

      old = $stdout
      $stdout = tty_stringio
      begin
        ui = described_class.new
        ui.thinking_started
        sleep 0.15

        composer.handle_key("/")
        expect(composer.menu_open?).to be(true)
        expect(composer.instance_variable_get(:@menu).items).to include("/help")

        composer.handle_key("\x7F") # backspace the "/"
        composer.handle_key("@")
        expect(composer.menu_open?).to be(true)
        expect(composer.instance_variable_get(:@menu).items).not_to be_empty

        ui.thinking_finished
      ensure
        $stdout = old
      end
    end
  end

  describe "thinking ticker with NO composer (one-shot / cooked /probe wait)" do
    it "keeps the in-place CR repaint on a bare TTY (#58)" do
      old = $stdout
      $stdout = tty_stringio
      begin
        ui = described_class.new
        ui.thinking_started
        sleep 0.25
        ui.thinking_finished

        expect($stdout.string).to include("\r\e[2K")
        expect($stdout.string).to include("thinking")
      ensure
        $stdout = old
      end
    end
  end

  describe "turn-scoped status row (V3 'Ruby facet')" do
    # A live-capable stdout double: frames route through #live (the StdoutProxy
    # seam), committed rows through the normal print path.
    def live_stringio
      Class.new(StringIO) do
        def live(str)
          write(str)
          self
        end

        def tty? = true
      end.new
    end

    it "keeps ONE engine thread across label swaps (thinking → tool → thinking) and stops at turn end" do
      old = $stdout
      $stdout = live_stringio
      begin
        ui = described_class.new
        ui.turn_started
        thread = ui.instance_variable_get(:@thinking_thread)
        expect(thread).to be_a(Thread)
        sleep 0.15
        expect($stdout.string).to include("thinking · 0")

        ui.tool_started("shell", arguments: { command: "npm test" })
        # Label swap, not thread churn: the SAME engine thread keeps ticking.
        expect(ui.instance_variable_get(:@thinking_thread)).to equal(thread)
        sleep 0.15
        expect($stdout.string).to include("shell · npm test · 0")

        ui.tool_finished("shell", result: nil)
        expect(ui.instance_variable_get(:@thinking_thread)).to equal(thread)
        sleep 0.15
        expect($stdout.string).to include("1 tool")

        ui.turn_finished
        expect(ui.instance_variable_get(:@thinking_thread)).to be_nil
        expect(thread).not_to be_alive
      ensure
        $stdout = old
      end
    end

    it "switches to 'polishing · <job>' for the post-turn inline jobs (P6)" do
      old = $stdout
      $stdout = live_stringio
      begin
        ui = described_class.new
        ui.turn_started
        ui.job_started("ExtractMemoryJob")
        sleep 0.15
        expect($stdout.string).to include("polishing · memory · 0")

        ui.job_finished("ExtractMemoryJob")
        ui.job_started("DistillSkillJob")
        sleep 0.15
        expect($stdout.string).to include("polishing · skills · 0")

        ui.turn_finished
        expect(ui.instance_variable_get(:@thinking_thread)).to be_nil
      ensure
        $stdout = old
      end
    end

    it "renders the landed facet in the `◆ turn` footer note" do
      ui = described_class.new
      ui.instance_variable_set(:@pastel, Pastel.new(enabled: false))
      old = $stdout
      $stdout = StringIO.new
      begin
        ui.note("◆ turn · 7.1s · 1 tool · 371 tok")
        expect($stdout.string).to include("┄ ◆ turn · 7.1s · 1 tool · 371 tok ┄")
      ensure
        $stdout = old
      end
    end
  end

  describe "a suspended composer (run_in_terminal)" do
    it "drops live frames instead of painting over the interactive prompt" do
      composer = Rubino::UI::BottomComposer.new(input_queue: queue, input: StringIO.new,
                                                output: output)
      composer.instance_variable_set(:@suspended, true)
      composer.set_partial("✳ thinking…  3s")
      expect(output.string).to eq("")
    end
  end
end
# rubocop:enable RSpec/ExpectOutput
