# frozen_string_literal: true

# The inline CLI UI uses compact append-only timeline rendering.
# Visual language:
#   ●  active tool or activity
#   ✓  completed successfully
#   ✗  failed
#   ◆  approval required
#   ┄  low-priority metadata
#
# No boxes, no per-element timestamps, no horizontal rules across the terminal.
RSpec.describe Rubino::UI::CLI do
  subject(:ui) { described_class.new }

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  # Timeline convention: activity lines use ● / ✓ / ✗ / ◆ markers
  ACTIVITY_START = /● /
  ACTIVITY_DONE  = /└ ✓/
  ACTIVITY_FAIL  = /✗ failed/

  describe "#stream" do
    it "prints streamed content directly without a box" do
      out = capture_stdout do
        ui.stream(type: :content, text: "hello")
        ui.stream_end
      end
      expect(out).to include("hello")
      expect(out).not_to include("┌─")
    end

    it "buffers thinking text instead of raw-printing it (bug #2)" do
      out = capture_stdout do
        ui.stream(type: :thinking, text: "musing")
      end
      # Reasoning is NEVER raw-printed — it accumulates in the buffer so the
      # collapse cue / full aside / ctrl-o reveal can render it in house style.
      expect(out).not_to include("musing")
      expect(ui.instance_variable_get(:@reasoning_buffer)).to eq("musing")
    end

    it "collapses buffered reasoning into a dim cue when the answer arrives" do
      ui.instance_variable_set(:@pastel, Pastel.new(enabled: false))
      out = capture_stdout do
        ui.thinking_started
        ui.stream(type: :thinking, text: "musing")
        ui.stream(type: :content, text: "hello")
        ui.stream_end
      end
      expect(out).to match(/┄ ✻ thought for \d+s · ctrl-o to show ┄/)
      expect(out).to include("hello")
      expect(out).not_to include("musing")
    end

    it "renders reasoning as a dim ┊ aside in full mode" do
      ui.instance_variable_set(:@pastel, Pastel.new(enabled: false))
      Rubino.configuration.set("display", "reasoning", "full")
      out = capture_stdout do
        ui.thinking_started
        ui.stream(type: :thinking, text: "Let me check the failing test first.\n")
        ui.stream(type: :content, text: "done")
        ui.stream_end
      end
      expect(out).to include("┄ thinking ┄")
      expect(out).to include("┊  Let me check the failing test first.")
      # A shown aside is append-only scrollback that can't be un-shown, so its
      # close line carries NO toggle promise (neither "to hide" nor "to show").
      expect(out).to match(/┄ thought for \d+s ┄/)
      expect(out).not_to include("ctrl-o to hide")
      expect(out).not_to include("ctrl-o to show")
      expect(out).to include("done")
    end

    it "commits nothing for reasoning in hidden mode" do
      ui.instance_variable_set(:@pastel, Pastel.new(enabled: false))
      Rubino.configuration.set("display", "reasoning", "hidden")
      out = capture_stdout do
        ui.thinking_started
        ui.stream(type: :thinking, text: "secret musing")
        ui.stream(type: :content, text: "answer")
        ui.stream_end
      end
      expect(out).not_to include("thought for")
      expect(out).not_to include("secret musing")
      expect(out).to include("answer")
    end

    # Regression for #76: the hidden-mode ack promises "ctrl-o … to bring it
    # back", but hidden mode never retained the buffer, so Ctrl-O was a silent
    # no-op. Hidden now commits nothing but still retains the last thought.
    it "retains the last reasoning in hidden mode so ctrl-o can reveal it (#76)" do
      ui.instance_variable_set(:@pastel, Pastel.new(enabled: false))
      Rubino.configuration.set("display", "reasoning", "hidden")
      turn = capture_stdout do
        ui.thinking_started
        ui.stream(type: :thinking, text: "secret musing\n")
        ui.stream(type: :content, text: "answer")
        ui.stream_end
      end
      expect(turn).not_to include("secret musing") # still hidden by default

      out = capture_stdout { ui.reveal_last_reasoning }
      expect(out).to include("┄ thinking ┄")
      expect(out).to include("┊  secret musing")
    end

    it "reveals the last retained reasoning buffer via ctrl-o (one-way)" do
      ui.instance_variable_set(:@pastel, Pastel.new(enabled: false))
      # Collapse a reasoning phase (collapsed mode) so the buffer is retained.
      capture_stdout do
        ui.thinking_started
        ui.stream(type: :thinking, text: "Let me check the failing test first.\n")
        ui.stream(type: :content, text: "ok")
        ui.stream_end
      end
      out = capture_stdout { ui.reveal_last_reasoning }
      expect(out).to include("┄ thinking ┄")
      expect(out).to include("┊  Let me check the failing test first.")
      # The reveal JUST showed the reasoning, so its close line must NOT promise
      # "to show" (redundant) nor "to hide" (a scrollback aside can't be hidden).
      expect(out).to match(/┄ thought for \d+s ┄/)
      expect(out).not_to include("ctrl-o to show")
      expect(out).not_to include("ctrl-o to hide")
    end

    it "ctrl-o reveal is idempotent — a second press is a SILENT no-op (D2)" do
      ui.instance_variable_set(:@pastel, Pastel.new(enabled: false))
      capture_stdout do
        ui.thinking_started
        ui.stream(type: :thinking, text: "first thought.\n")
        ui.stream(type: :content, text: "ok")
        ui.stream_end
      end
      first  = capture_stdout { ui.reveal_last_reasoning }
      second = capture_stdout { ui.reveal_last_reasoning }
      third  = capture_stdout { ui.reveal_last_reasoning }
      expect(first).to include("┊  first thought.")
      # Every subsequent press prints NOTHING — no aside, and no ack line
      # ("┄ already shown ┄" was scrollback spam; D2 removed it). True silence.
      expect(second).not_to include("┊  first thought.")
      expect(second).not_to include("┄ thinking ┄")
      expect(second).not_to include("already shown")
      expect(second).to eq("")
      expect(third).to eq("")
    end

    it "a NEW retained thought resets the reveal guard so its first ctrl-o works" do
      ui.instance_variable_set(:@pastel, Pastel.new(enabled: false))
      capture_stdout do
        ui.thinking_started
        ui.stream(type: :thinking, text: "thought one.\n")
        ui.stream(type: :content, text: "a")
        ui.stream_end
      end
      capture_stdout { ui.reveal_last_reasoning } # reveal first thought
      # A fresh turn retains a NEW thought — the guard resets.
      capture_stdout do
        ui.thinking_started
        ui.stream(type: :thinking, text: "thought two.\n")
        ui.stream(type: :content, text: "b")
        ui.stream_end
      end
      out = capture_stdout { ui.reveal_last_reasoning }
      expect(out).to include("┊  thought two.")
      expect(out).not_to include("┄ already shown ┄")
    end

    it "ctrl-o with nothing retained prints a dim one-shot note, then stays silent (#133)" do
      ui.instance_variable_set(:@pastel, Pastel.new(enabled: false))
      # First press: the advertised key must give SOME feedback instead of
      # reading as a broken keybinding on providers that stream no thinking.
      out = capture_stdout { ui.reveal_last_reasoning }
      expect(out).to include("no reasoning retained")
      # Further presses in the same dry spell stay silent (no stacking notes).
      expect { ui.reveal_last_reasoning }.not_to output.to_stdout
    end

    it "acknowledges hiding reasoning with an explanatory line (→ hidden)" do
      ui.instance_variable_set(:@pastel, Pastel.new(enabled: false))
      out = capture_stdout { ui.reasoning_changed(:hidden, previous: :full) }
      expect(out).to include("┄ reasoning hidden — won't be shown (ctrl-o or /reasoning to bring it back) ┄")
      expect(out).not_to include("full → hidden")
    end

    it "keeps the terse arrow for transitions that are not → hidden" do
      ui.instance_variable_set(:@pastel, Pastel.new(enabled: false))
      out = capture_stdout { ui.reasoning_changed(:full, previous: :collapsed) }
      expect(out).to include("┄ reasoning collapsed → full ┄")
    end

    it "clears thinking indicator when first content chunk arrives" do
      out = capture_stdout do
        ui.thinking_started
        # The erase-line escape is TTY-only (#56): flip tty? on AFTER the
        # static indicator printed so the clear path runs as on a terminal.
        allow($stdout).to receive(:tty?).and_return(true)
        ui.stream(type: :content, text: "hello")
      end
      expect(out).to match(/thinking….*\r\e\[2K.*hello/m)
    end

    it "ignores empty chunk text" do
      expect { ui.stream(type: :content, text: "") }.not_to output.to_stdout
    end

    it "animates the thinking row through #live and stops the timer cleanly" do
      # A live-capable stdout double drives the animated path (not the static
      # plain-mode print). The timer thread must start, then be joined/killed by
      # clear_thinking_indicator with no leak.
      live = Class.new(StringIO) do
        def live(str) = print(str)
      end.new
      old = $stdout
      $stdout = live
      begin
        ui.thinking_started
        expect(ui.instance_variable_get(:@thinking_thread)).to be_a(Thread)
        sleep 0.15 # let at least one frame paint
        ui.send(:clear_thinking_indicator)
        expect(ui.instance_variable_get(:@thinking_thread)).to be_nil
        expect(ui.instance_variable_get(:@thinking_indicator)).to be(false)
        expect(live.string).to include("thinking")
      ensure
        $stdout = old
      end
    end

    it "thinking_started/clear are safe to call repeatedly" do
      expect do
        ui.thinking_started
        ui.thinking_started
        ui.send(:clear_thinking_indicator)
        ui.send(:clear_thinking_indicator)
      end.not_to raise_error
    end

    # Regression for #74: a turn that ends in ERROR used to leave the animated
    # "thinking…" row ticking forever — the runner's rescue printed the error
    # without ever tearing the animation down, corrupting all later output.
    it "tears down the live thinking animation when the turn ends in error (#74)" do
      live = Class.new(StringIO) do
        def live(str) = print(str)
      end.new
      old = $stdout
      $stdout = live
      begin
        ui.thinking_started
        expect(ui.instance_variable_get(:@thinking_thread)).to be_a(Thread)
        ui.error("model exploded")
        expect(ui.instance_variable_get(:@thinking_thread)).to be_nil
        expect(ui.instance_variable_get(:@thinking_indicator)).to be(false)
        expect(live.string).to include("model exploded")
      ensure
        $stdout = old
      end
    end

    it "clears the static thinking row before the error line on the plain path (#74)" do
      out = capture_stdout do
        ui.thinking_started
        allow($stdout).to receive(:tty?).and_return(true) # erase is TTY-only (#56)
        ui.error("provider failure")
      end
      expect(out).to match(/thinking….*\r\e\[2K.*provider failure/m)
      expect(ui.instance_variable_get(:@thinking_indicator)).to be(false)
    end

    it "tears down a still-live thinking row on interrupt too (#74)" do
      out = capture_stdout do
        ui.thinking_started
        ui.turn_interrupted
      end
      expect(out).to include("⎿ interrupted")
      expect(ui.instance_variable_get(:@thinking_indicator)).to be(false)
      expect(ui.instance_variable_get(:@thinking_thread)).to be_nil
    end

    it "handles multi-line streamed text" do
      out = capture_stdout do
        ui.stream(type: :content, text: "first\nsecond\n")
        ui.stream_end
      end
      expect(out).to include("first")
      expect(out).to include("second")
    end
  end

  describe "#stream markdown rendering (per-block commit)" do
    before { ui.instance_variable_set(:@pastel, Pastel.new(enabled: true)) }

    it "renders the COMMITTED block as styled markdown, not raw markup" do
      out = capture_stdout do
        ui.stream(type: :content, text: "**bold** word\n")
        ui.stream_end
      end
      # The committed line carries bold ANSI around the word (not the literal
      # **bold**). The raw tail shown transiently before commit may still hold
      # the markup; what matters is the committed render is styled.
      expect(out).to match(/\e\[1mbold\e\[0m word/)
    end

    it "fits a wide table to the terminal width minus the 2-space indent" do
      # Pin a narrow-but-usable terminal so the assertion is deterministic.
      console = instance_double(IO, winsize: [24, 60])
      allow(IO).to receive(:console).and_return(console)

      md = "| Name | Description |\n|---|---|\n" \
           "| alpha | a description long enough to force the table to wrap across several lines |\n"
      out = capture_stdout { ui.assistant_text(md) }

      # Every committed line (incl. the 2-space indent) fits the 60-col terminal.
      visible = out.split("\n").map { |l| l.gsub(/\e\[[0-9;]*m/, "") }
      table_lines = visible.select { |l| l.include?("│") || l.include?("┌") || l.include?("└") }
      expect(table_lines).not_to be_empty
      table_lines.each { |l| expect(l.length).to be <= 60 }
    end

    # #95: while streaming a table the bottom-composer raw-mode TUI can make
    # `winsize` under-report the column count (tiny or zero). With the old
    # `[(cols||80)-2, 1].max` floor the budget dropped to ~1, TTY::Table resized
    # every column to ~1 char, and headers stacked vertically (L/a/n/g/u/a/g/e).
    # The width detector must clamp to a usable minimum so columns stay readable.
    it "keeps streamed-table columns readable when winsize under-reports (#95)" do
      headers = %w[Language Type Concurrency]
      md = "| #{headers.join(" | ")} |\n|---|---|---|\n" \
           "| Ruby | Dynamic | GIL + threads/fibers; async |\n"

      # Tiny positive winsize (the streaming under-report) and a zero/garbage one
      # both used to collapse the table; neither may now.
      [[24, 2], [24, 0]].each do |winsize|
        console = instance_double(IO, winsize: winsize)
        allow(IO).to receive(:console).and_return(console)

        out = capture_stdout { ui.assistant_text(md) }
        visible = out.split("\n").map { |l| l.gsub(/\e\[[0-9;]*m/, "") }

        header_row = visible.find { |l| l.include?("Language") || l.include?("Concurrency") }
        expect(header_row).not_to be_nil,
                                  "winsize #{winsize.inspect}: no header row rendered (#{visible.inspect})"

        # The first column held the 8-char "Language" header. Pre-fix the budget
        # collapsed to ~1 (then bottomed out at the renderer's MIN_TABLE_WIDTH=20
        # clamp), squeezing every column to ~1-2 chars and stacking the header
        # vertically. Post-fix the width detector floors at a usable budget, so
        # the first column carries most of the word on one row.
        first_col = header_row[/│([^│]*)│/, 1].to_s.strip
        expect(first_col.length).to be >= 6,
                                    "winsize #{winsize.inspect}: first column collapsed to #{first_col.inspect}"

        # The committed table is far wider than the degenerate render, which
        # bottoms out at MIN_TABLE_WIDTH (20). A budget-driven width clears that.
        expect(visible.map(&:length).max).to be >= 30,
                                             "winsize #{winsize.inspect}: table never exceeded the collapse clamp (#{visible.inspect})"
      end
    end

    it "renders a heading without the literal '#'" do
      out = capture_stdout do
        ui.stream(type: :content, text: "# Title\n\n")
        ui.stream_end
      end
      expect(out).to include("Title")
      expect(out).to match(/\e\[/) # styled (cyan/bold), not raw
    end

    it "commits a prose block as soon as a blank line ends it (before stream_end)" do
      out = capture_stdout do
        ui.stream(type: :content, text: "first block\n\n")
        # No stream_end yet — the completed block must already be committed.
      end
      expect(out).to include("first block")
    end

    it "does NOT commit (render) a code fence until it is closed" do
      mid = capture_stdout do
        ui.stream(type: :content, text: "```ruby\nputs 1\n")
      end
      # The styled code-block frame is only emitted on commit; mid-stream the
      # open fence is shown raw in the live tail, not rendered.
      expect(mid).not_to include("┌─") # no rendered code-block frame yet

      done = capture_stdout do
        ui.stream(type: :content, text: "```\n")
        ui.stream_end
      end
      expect(done).to include("┌─") # frame appears once the fence closes
      expect(done).to include("puts 1")
    end

    it "flushes the trailing block on stream_end (no closing blank line)" do
      out = capture_stdout do
        ui.stream(type: :content, text: "trailing line with no blank")
        ui.stream_end
      end
      expect(out).to include("trailing line with no blank")
    end

    it "emits an unclosed fence as PLAIN text on stream_end (never lost)" do
      out = capture_stdout do
        ui.stream(type: :content, text: "```ruby\nputs 42\n")
        ui.stream_end # fence never closed by the model
      end
      expect(out).to include("puts 42")
      expect(out).to include("```ruby") # plain fallback keeps the fence markup
    end

    it "no longer prints raw markup straight through for content" do
      out = capture_stdout do
        ui.stream(type: :content, text: "## Heading\n\n")
        ui.stream_end
      end
      expect(out).not_to include("## Heading")
    end

    it "shows the in-progress tail via the live seam when $stdout supports it" do
      live_io = Class.new(StringIO) do
        attr_reader :live_calls

        def live(str)
          (@live_calls ||= []) << str
          self
        end
      end.new

      old = $stdout
      $stdout = live_io
      begin
        ui.stream(type: :content, text: "incomplete ta")
      ensure
        $stdout = old
      end
      expect(live_io.live_calls).to include("#{described_class::MD_MARGIN}incomplete ta")
    end

    it "prefixes every live-tail row with the committed-markdown left margin" do
      # The raw in-flight tail must sit in the SAME column as the rendered
      # block it snaps into: committed lines are printed behind MD_MARGIN
      # (#commit_markdown_block), so a flush-left tail under them read as a
      # jarring seam. Every row of a multi-line tail carries the margin.
      live_io = Class.new(StringIO) do
        attr_reader :live_calls

        def live(str)
          (@live_calls ||= []) << str
          self
        end
      end.new

      old = $stdout
      $stdout = live_io
      begin
        ui.stream(type: :content, text: "- one\n- two\n- thr")
      ensure
        $stdout = old
      end

      margin = described_class::MD_MARGIN
      rows = live_io.live_calls.last.split("\n")
      expect(rows).to all(start_with(margin))
      expect(rows.last).to eq("#{margin}- thr")
    end

    it "shows a bounded rolling tail of the in-flight block on the live seam (#127)" do
      # Regression (one-row era): a half-arrived multi-line block sent only its
      # current raw line to the live region, so the earlier lines the user had
      # just watched stream by VANISHED until the whole block committed. The
      # live seam now receives the last LIVE_TAIL_ROWS lines of the in-flight
      # block — recent context stays visible, and the window is bounded so a
      # long block can never grow the live region unbounded.
      live_io = Class.new(StringIO) do
        attr_reader :live_calls

        def live(str)
          (@live_calls ||= []) << str
          self
        end
      end.new

      old = $stdout
      $stdout = live_io
      begin
        ui.stream(type: :content, text: "| Gem | Use |\n| --- | --- |\n| ruby_llm | LLM")
      ensure
        $stdout = old
      end

      margin = described_class::MD_MARGIN
      expect(live_io.live_calls.last)
        .to eq("#{margin}| Gem | Use |\n#{margin}| --- | --- |\n#{margin}| ruby_llm | LLM")
      rows = described_class::LIVE_TAIL_ROWS
      expect(live_io.live_calls).to all(satisfy { |s| s.split("\n").length <= rows })
    end

    it "does not crash on the plain path when $stdout has no #live" do
      expect do
        capture_stdout do
          ui.stream(type: :content, text: "plain **md** here\n\n")
          ui.stream_end
        end
      end.not_to raise_error
    end
  end

  describe "#thinking_started" do
    it "prints a transient 'thinking…' indicator" do
      expect { ui.thinking_started }.to output(/thinking…/).to_stdout
    end

    it "is erased before the first content chunk lands" do
      out = capture_stdout do
        ui.thinking_started
        allow($stdout).to receive(:tty?).and_return(true) # erase is TTY-only (#56)
        ui.stream(type: :content, text: "hello")
      end
      expect(out).to match(/thinking….*\r\e\[2K.*hello/m)
    end

    it "is a no-op if a stream is already open" do
      ui.stream(type: :content, text: "partial")
      expect { ui.thinking_started }.not_to output(/thinking…/).to_stdout
    end
  end

  describe "#tool_started" do
    # P1 polarity: the open row is QUIET — dim name + hint, only the ● cyan.
    it "renders as compact '● name hint'" do
      out = capture_stdout do
        ui.tool_started("shell", arguments: { command: "ls" })
      end
      expect(out).to include("● shell ls")
      expect(out).not_to include("running")
      expect(out).not_to include("┌─")
    end

    it "renders only the ● in cyan; the name/hint stay dim (P1)" do
      ui.instance_variable_set(:@pastel, Pastel.new(enabled: true))
      out = capture_stdout do
        ui.tool_started("shell", arguments: { command: "ls" })
      end
      expect(out).to include("\e[36m●\e[0m")          # cyan glyph only
      expect(out).to include("\e[2mshell ls\e[0m")    # dim name + hint
      expect(out).not_to include("\e[36m●\e[0m\e[36m") # nothing else cyan
    end

    it "renders as '● name' when no args given" do
      out = capture_stdout { ui.tool_started("ping", arguments: nil) }
      expect(out).to include("● ping")
      expect(out).not_to match(/· \S/)
    end

    it "truncates long arg hints with an ellipsis" do
      long = "x" * 200
      expect { ui.tool_started("shell", arguments: { command: long }) }
        .to output(/\.\.\./).to_stdout
    end

    # Regression for #136: on the streaming path the model emits answer text
    # right up to the tool call (ruby_llm runs the tool mid-stream, no
    # stream_end intervenes). The buffered pre-tool segment must COMMIT BEFORE
    # the tool card — in stream order — and stay a separate block from the
    # post-tool continuation, never "…number.Confirmed — …" glue after the card.
    it "commits the buffered pre-tool stream text BEFORE the tool card (#136)" do
      out = capture_stdout do
        ui.stream(type: :content, text: "Starting the subagent to compute the number.")
        ui.tool_started("task", arguments: { prompt: "fib(25)" })
        ui.tool_finished("task", result: nil)
        ui.stream(type: :content, text: "Confirmed — it is running.")
        ui.stream_end
      end

      pre  = out.index("compute the number.")
      card = out.index("delegated")
      post = out.index("Confirmed — it is running.")
      expect(pre).not_to be_nil
      expect(card).not_to be_nil
      expect(post).not_to be_nil
      expect(pre).to be < card           # pre-tool text before the card (stream order)
      expect(card).to be < post          # post-tool text after the card
      expect(out).not_to include("number.Confirmed") # never glued into one word
    end
  end

  describe "#tool_finished" do
    # P10: success close is compact — the ✓ says done, the opener said the
    # name. Dim, not green (P1: color only on failure).
    it "renders a compact '└ ✓' on success" do
      out = capture_stdout do
        ui.tool_started("shell", arguments: { command: "ls" })
        ui.tool_finished("shell", result: nil)
      end
      expect(out).to include("└ ✓")
      expect(out).not_to include("✓ done")
    end

    it "renders the success close dim, never green (P1)" do
      ui.instance_variable_set(:@pastel, Pastel.new(enabled: true))
      result = double("Result", truncated_preview: "11 lines", success?: true, metrics: "11 lines")
      out = capture_stdout do
        ui.tool_started("read", arguments: nil)
        ui.tool_finished("read", result: result)
      end
      expect(out).to include("\e[2m  └ ✓ 11 lines\e[0m")
      expect(out).not_to include("\e[32m  └")
    end

    it "renders as '✗ failed · name' on failure" do
      result = double("Result", success?: false, truncated_preview: "error")
      out = capture_stdout do
        ui.tool_started("shell", arguments: nil)
        ui.tool_finished("shell", result: result)
      end
      expect(out).to include("✗ failed · shell")
    end

    it "shows metric on success when result provides it" do
      result = double("Result", truncated_preview: "42 files", success?: true, metrics: nil)
      out = capture_stdout do
        ui.tool_started("ls", arguments: nil)
        ui.tool_finished("ls", result: result)
      end
      expect(out).to include("└ ✓ 42 files")
    end

    it "shows error message on failure" do
      result = double("Result", success?: false, truncated_preview: "not found")
      out = capture_stdout do
        ui.tool_started("read", arguments: nil)
        ui.tool_finished("read", result: result)
      end
      expect(out).to include("✗ failed · read · not found")
    end

    # B7: a tool that signals failure by RETURNING an "Error: …" string (status
    # stays :success — read/edit do this for not-found, etc.) used to render the
    # green "✓ done" success icon. It must render "✗".
    it "renders '✗' when a successful-status result carries an Error: output (B7)" do
      result = Rubino::Tools::Result.success(
        name: "read", call_id: "c1", output: "Error: File not found: nope.txt"
      )
      out = capture_stdout do
        ui.tool_started("read", arguments: nil)
        ui.tool_finished("read", result: result)
      end
      expect(out).to include("✗ failed · read")
      expect(out).not_to include("✓ done · read")
    end
  end

  # #123: the `task` (delegation) card is the B7 family on the delegation row.
  # The task tool reports failures by RETURNING an error STRING ("Error: …",
  # "At capacity: …"), which the executor wraps in a SUCCESS-status Result, so
  # the row used to render a misleading green ✓. A failed delegation must show ✗.
  describe "#tool_finished (task delegation card)" do
    def render_delegation(result)
      capture_stdout do
        ui.tool_started("task", arguments: { subagent: "explore", prompt: "hi" })
        ui.tool_finished("task", result: result)
      end
    end

    # #105: the delegation header label is user-facing UI and must be English
    # ("delegated", not the Italian "delegato").
    it "renders an English 'delegated →' header for the delegation row (#105)" do
      out = capture_stdout { ui.tool_started("task", arguments: { subagent: "explore", prompt: "hi" }) }
      expect(out).to include("● delegated → explore")
      expect(out).not_to include("delegato")
    end

    it "renders ✓ when the delegation succeeded" do
      result = Rubino::Tools::Result.success(
        name: "task", call_id: "t1", output: "Started background subagent 'explore' as task sa_1."
      )
      out = render_delegation(result)
      expect(out).to include("✓ explore")
      expect(out).not_to include("✗ explore")
    end

    it "renders ✗ when the task tool returned an Error: string (success-status Result)" do
      result = Rubino::Tools::Result.success(
        name: "task", call_id: "t1",
        output: "Error: unknown subagent 'nonexistent-agent'. Valid subagents: explore, general."
      )
      out = render_delegation(result)
      expect(out).to include("✗ explore")
      expect(out).not_to include("✓ explore")
    end

    it "renders ✗ when the task tool returned an At capacity: string" do
      result = Rubino::Tools::Result.success(
        name: "task", call_id: "t1",
        output: "At capacity: 3 background subagents are already running."
      )
      out = render_delegation(result)
      expect(out).to include("✗ explore")
      expect(out).not_to include("✓ explore")
    end

    it "renders ✗ when the result has error status (synchronous subagent raised)" do
      result = Rubino::Tools::Result.error(
        name: "task", call_id: "t1", error: "subagent 'explore' failed: boom"
      )
      out = render_delegation(result)
      expect(out).to include("✗ explore")
      expect(out).not_to include("✓ explore")
    end
  end

  # #106/#107: off a real terminal TTY::Prompt would leak raw cursor-control
  # escapes (ESC[4A / ESC[2K / ESC[1G) into the piped stream and read whatever
  # ambient stdin held. #ask must fail closed: deterministic nil, zero output.
  describe "#ask off a TTY" do
    it "returns nil and emits nothing when stdout is not a TTY (#106)" do
      out = capture_stdout do
        expect(ui.ask("Red or blue?")).to be_nil
      end
      expect(out).to eq("")
    end
  end

  describe "#replay_user_input" do
    it "renders the past user turn as plain text" do
      out = capture_stdout { ui.replay_user_input("hello again") }
      expect(out).to include("hello again")
      expect(out).not_to include("┌─")
    end

    it "stringifies non-string content without raising" do
      expect { ui.replay_user_input(nil) }.not_to raise_error
    end
  end

  # #62: integration coverage for the CLI ↔ composer Ctrl+O reveal-deferral
  # seam (mirrors the interrupt-wiring regression test). mark_content_streaming
  # has no respond_to?/blanket-rescue safety net anymore, so a signature drift
  # on begin/end_content_stream fails HERE instead of silently un-gating the
  # mid-stream reveal (D1).
  describe "#mark_content_streaming (Ctrl+O reveal-deferral seam, #62)" do
    after { Rubino::UI::BottomComposer.current = nil }

    def composer_with_reveal_spy(reveals)
      Rubino::UI::BottomComposer.new(
        input_queue: Rubino::Interaction::InputQueue.new,
        input: StringIO.new, output: StringIO.new,
        on_ctrl_o: -> { reveals << :reveal }
      )
    end

    it "defers a mid-stream Ctrl+O and flushes it when the CLI ends the stream" do
      reveals  = []
      composer = composer_with_reveal_spy(reveals)
      Rubino::UI::BottomComposer.current = composer

      ui.send(:mark_content_streaming, true) # CLI: first answer token arrived
      expect(composer.streaming?).to be(true)

      composer.handle_key("\x0f") # Ctrl+O mid-stream: deferred, not fired
      expect(reveals).to be_empty

      ui.send(:mark_content_streaming, false) # CLI: stream_end / finalize
      expect(composer.streaming?).to be(false)
      expect(reveals).to eq([:reveal]) # the deferred reveal flushed once
    end

    it "reveals immediately when no content stream is active" do
      reveals  = []
      composer = composer_with_reveal_spy(reveals)
      Rubino::UI::BottomComposer.current = composer

      composer.handle_key("\x0f")
      expect(reveals).to eq([:reveal])
    end
  end

  describe "#input_injected" do
    after { Rubino::UI::BottomComposer.current = nil }

    # #129: a line the loop folded into the CURRENT turn as steering has been
    # consumed — its live "⏳ queued:" indicator must clear, or it would sit
    # above the input forever for a message that already ran.
    it "clears the consumed line's pending indicator on the current composer (#129)" do
      pending  = ["fold me in"]
      composer = Rubino::UI::BottomComposer.new(
        input_queue: Rubino::Interaction::InputQueue.new,
        input: StringIO.new, output: StringIO.new, pending_queued: pending
      )
      Rubino::UI::BottomComposer.current = composer

      capture_stdout { ui.input_injected("fold me in") }

      expect(pending).to eq([])
    end

    it "clears indicators for each line of a coalesced injection (#129)" do
      pending  = %w[alpha beta]
      composer = Rubino::UI::BottomComposer.new(
        input_queue: Rubino::Interaction::InputQueue.new,
        input: StringIO.new, output: StringIO.new, pending_queued: pending
      )
      Rubino::UI::BottomComposer.current = composer

      capture_stdout { ui.input_injected("alpha\nbeta") }

      expect(pending).to eq([])
    end

    it "echoes the injected text dim with the ↳ marker" do
      out = capture_stdout { ui.input_injected("steered note") }
      expect(out).to include("↳ received while working: steered note")
    end
  end

  describe "#note" do
    it "renders a free line wrapped in `┄` bookends" do
      expect { ui.note("turn · 9s · 0 tools · 1.3k tok") }
        .to output(/┄ turn · 9s · 0 tools · 1\.3k tok ┄/).to_stdout
    end
  end

  describe "#input_injected" do
    # #137: the fold-in confirmation leaked Italian ("ricevuto mentre
    # lavoravo") into an English UI. It must be English.
    it "prefixes the echo in English, never Italian (#137)" do
      out = capture_stdout { ui.input_injected("be terse") }
      expect(out).to include("↳ received while working: be terse")
      expect(out).not_to include("ricevuto")
    end

    # #139: a multi-line [background-task] completion notice carries the
    # child's markdown report — the body renders through the markdown
    # pipeline (no literal ## / ** artifacts), prefix stays on line 1 only.
    it "renders a multi-line notice body through the markdown pipeline (#139)" do
      notice = "[background-task] Task sa_1 (subagent 'general') completed.\n" \
               "Result:\n## Summary\n**Computed value:** 75025"
      out = capture_stdout { ui.input_injected(notice) }
      plain = out.gsub(/\e\[[0-9;]*m/, "")
      expect(plain).to include("↳ received while working: [background-task] Task sa_1")
      expect(plain).to include("Summary")
      expect(plain).not_to include("## Summary")
      expect(plain).not_to include("**Computed value:**")
    end
  end

  describe "#subagent_ask_banner" do
    # #145: the banner claimed "no timeout" while tasks.ask_parent_timeout
    # defaults to 900s — the child auto-resumes. The banner must tell the truth.
    it "reads the configured ask_parent timeout instead of claiming 'no timeout' (#145)" do
      out = capture_stdout { ui.subagent_ask_banner("sa_1", "general", "Which license?") }
      expect(out).to include("auto-resumes with its best judgement in 15m")
      expect(out).not_to include("no timeout")
    end

    it "says 'no timeout' only when the bound is explicitly disabled (#145)" do
      allow(Rubino.configuration).to receive(:tasks_ask_parent_timeout).and_return(nil)
      out = capture_stdout { ui.subagent_ask_banner("sa_1", "general", "Which license?") }
      expect(out).to include("no timeout")
    end
  end

  # #84: a table that overflows a narrow terminal degrades to a readable
  # vertical card layout — full field labels, identifying field first, and a
  # rule between records — instead of an overflowing grid.
  describe "#table narrow-terminal card fallback" do
    def with_cols(n)
      console = instance_double(IO, winsize: [24, n])
      allow(IO).to receive(:console).and_return(console)
    end

    it "renders the unicode grid when it fits the terminal" do
      with_cols(120)
      out = capture_stdout { ui.table(headers: %w[ID Title], rows: [%w[abc123 hello]]) }
      expect(out).to include("│") # grid box-drawing present
    end

    it "degrades to vertical cards when the grid would overflow" do
      with_cols(24)
      out = capture_stdout do
        ui.table(headers: %w[ID Title Created], rows: [["abc123", "a longer session title", "2026-06-07 00:04"]])
      end
      plain = out.gsub(/\e\[[0-9;]*m/, "")
      # Each field on its own line with its FULL label (no Cre… truncation).
      expect(plain).to match(/^ID\s+abc123/)
      expect(plain).to match(/^Title\s+a longer session title/)
      expect(plain).to match(/^Created\s+2026-06-07 00:04/)
      expect(plain).not_to include("Cre…")
    end

    it "separates multiple cards with a rule" do
      with_cols(24)
      out = capture_stdout do
        ui.table(headers: %w[ID Title],
                 rows: [["aaa", "a first session title"], ["bbb", "a second session title"]])
      end
      plain = out.gsub(/\e\[[0-9;]*m/, "")
      expect(plain).to include("─") # a separator rule between the two cards
      expect(plain.scan(/^ID\s+/).size).to eq(2)
    end
  end

  # #86: a transient "thinking…" indicator must be REPLACED by its result,
  # never left as residue above the answer.
  describe "thinking-indicator residue (#86)" do
    it "clears the indicator before a non-streamed assistant answer" do
      out = capture_stdout do
        ui.thinking_started
        allow($stdout).to receive(:tty?).and_return(true) # erase is TTY-only (#56)
        ui.assistant_text("the answer")
      end
      # The erase-line sequence is emitted before the committed answer.
      expect(out).to match(/thinking….*\r\e\[2K.*the answer/m)
    end

    it "clears the indicator before a tool activity row" do
      out = capture_stdout do
        ui.thinking_started
        allow($stdout).to receive(:tty?).and_return(true) # erase is TTY-only (#56)
        ui.tool_started("shell", arguments: { command: "ls" })
      end
      expect(out).to match(/thinking….*\r\e\[2K.*● shell/m)
    end
  end

  describe "#tool_body coloring per kind" do
    before { ui.instance_variable_set(:@pastel, Pastel.new(enabled: true)) }

    it "dims every line under :plain (no +/- coloring)" do
      out = capture_stdout do
        ui.tool_started("shell", arguments: { command: "ls -la" })
        ui.tool_body("-rw-r--r--  1 user staff  42 Jan 1 file.rb\n+ another line", kind: :plain)
        ui.tool_finished("shell", result: nil)
      end
      expect(out).to match(/\e\[2m.*-rw-r--r--/)
      expect(out).to match(/\e\[2m.*\+ another line/)
      expect(out).not_to match(/\e\[31m.*-rw-r--r--/)
      expect(out).not_to match(/\e\[32m.*\+ another line/)
    end

    it "colors +/- under :diff" do
      out = capture_stdout do
        ui.tool_started("edit", arguments: { file_path: "x.rb" })
        ui.tool_body("- old\n+ new", kind: :diff)
        ui.tool_finished("edit", result: nil)
      end
      expect(out).to match(/\e\[31m.*- old/)
      expect(out).to match(/\e\[32m.*\+ new/)
    end

    it "defaults to :plain when no kind given" do
      out = capture_stdout do
        ui.tool_started("shell", arguments: nil)
        ui.tool_body("- something")
        ui.tool_finished("shell", result: nil)
      end
      expect(out).not_to match(/\e\[31m.*- something/)
    end
  end

  # P2: DISPLAY-ONLY collapse of tool output in the transcript — head lines +
  # a "… +N lines (full output → context)" marker. The model-facing output is
  # produced elsewhere (ToolExecutor) and is untouched by this render path.
  describe "tool output preview collapse (P2)" do
    it "shows only the head 3 lines of a long #tool_body plus the marker" do
      out = capture_stdout do
        ui.tool_started("read", arguments: nil)
        ui.tool_body((1..10).map { |i| "line #{i}" }.join("\n"))
        ui.tool_finished("read", result: nil)
      end
      expect(out).to include("line 3")
      expect(out).not_to include("line 4")
      expect(out).to include("… +7 lines (full output → context)")
    end

    it "collapses streamed #tool_chunk lines, flushing the marker before the close row" do
      out = capture_stdout do
        ui.tool_started("shell", arguments: { command: "seq 9" })
        (1..9).each { |i| ui.tool_chunk("shell", "out #{i}\n") }
        ui.tool_finished("shell", result: nil)
      end
      expect(out).to include("out 3")
      expect(out).not_to include("out 4")
      marker = out.index("… +6 lines (full output → context)")
      close  = out.index("└ ✓")
      expect(marker).not_to be_nil
      expect(marker).to be < close
    end

    it "keeps a short body intact, with no marker" do
      out = capture_stdout do
        ui.tool_started("shell", arguments: nil)
        ui.tool_body("one\ntwo")
        ui.tool_finished("shell", result: nil)
      end
      expect(out).to include("one")
      expect(out).to include("two")
      expect(out).not_to include("full output → context")
    end

    it "honors display.tool_output_preview_lines = 0 as the old full dump" do
      allow(Rubino.configuration).to receive(:display_tool_output_preview_lines).and_return(0)
      out = capture_stdout do
        ui.tool_started("shell", arguments: nil)
        ui.tool_body((1..10).map { |i| "line #{i}" }.join("\n"))
        (1..5).each { |i| ui.tool_chunk("shell", "chunk #{i}\n") }
        ui.tool_finished("shell", result: nil)
      end
      expect(out).to include("line 10")
      expect(out).to include("chunk 5")
      expect(out).not_to include("full output → context")
    end

    it "resets the streamed-overflow counter between tool runs" do
      out = capture_stdout do
        ui.tool_started("shell", arguments: nil)
        (1..9).each { |i| ui.tool_chunk("shell", "first #{i}\n") }
        ui.tool_finished("shell", result: nil)
        ui.tool_started("shell", arguments: nil)
        ui.tool_chunk("shell", "second 1\n")
        ui.tool_finished("shell", result: nil)
      end
      expect(out.scan("full output → context").size).to eq(1)
      expect(out).to include("second 1")
    end
  end

  describe "#tool_started OSC 8 wrapping" do
    around do |ex|
      previous = ENV.to_h.slice("RUBINO_HYPERLINKS", "NO_COLOR", "TERM_PROGRAM", "TERM")
      ex.run
      ENV.delete("RUBINO_HYPERLINKS")
      ENV.delete("NO_COLOR")
      ENV.delete("TERM_PROGRAM")
      ENV.delete("TERM")
      previous.each { |k, v| ENV[k] = v }
      Rubino::Util::Hyperlink.reset!
    end

    it "wraps file_path in OSC 8 when the terminal supports it" do
      ENV["RUBINO_HYPERLINKS"] = "1"
      Rubino::Util::Hyperlink.reset!
      out = capture_stdout { ui.tool_started("read", arguments: { "file_path" => __FILE__ }) }
      expect(out).to include("\e]8;;file://#{__FILE__}\e\\")
    end

    it "wraps path in OSC 8 when the terminal supports it" do
      ENV["RUBINO_HYPERLINKS"] = "1"
      Rubino::Util::Hyperlink.reset!
      Dir.chdir(File.dirname(__FILE__)) do
        out = capture_stdout { ui.tool_started("glob", arguments: { "path" => "." }) }
        expect(out).to include("\e]8;;file://")
      end
    end

    it "emits plain text on unsupported terminals" do
      ENV["RUBINO_HYPERLINKS"] = "0"
      Rubino::Util::Hyperlink.reset!
      out = capture_stdout { ui.tool_started("read", arguments: { "file_path" => __FILE__ }) }
      expect(out).not_to include("\e]8;;")
    end

    it "never wraps pattern args (grep)" do
      ENV["RUBINO_HYPERLINKS"] = "1"
      Rubino::Util::Hyperlink.reset!
      out = capture_stdout { ui.tool_started("grep", arguments: { "pattern" => "TODO" }) }
      expect(out).not_to include("\e]8;;")
    end

    it "never wraps command args (shell)" do
      ENV["RUBINO_HYPERLINKS"] = "1"
      Rubino::Util::Hyperlink.reset!
      out = capture_stdout { ui.tool_started("shell", arguments: { "command" => "ls -la" }) }
      expect(out).not_to include("\e]8;;")
    end
  end

  describe "#confirm" do
    subject(:ui) do
      described_class.new(session_id: "sess-1", approval_cache: cache)
    end

    let(:cache) { Rubino::Run::SessionApprovalCache.new }

    # Stubs @prompt.select to return the choice symbol the menu would yield.
    def stub_choice(symbol)
      prompt = instance_double(TTY::Prompt)
      allow(prompt).to receive(:select).and_return(symbol)
      ui.instance_variable_set(:@prompt, prompt)
      prompt
    end

    it "prints the question with ◆ prefix before prompting" do
      stub_choice(:once)
      expect { ui.confirm("Allow shell with args?") }
        .to output(/◆ Allow shell with args/).to_stdout
    end

    it "clears a live 'thinking…' indicator before the approval card" do
      stub_choice(:once)
      out = capture_stdout do
        ui.thinking_started
        allow($stdout).to receive(:tty?).and_return(true) # erase is TTY-only (#56)
        ui.confirm("Allow shell with args?")
      end
      # The clear-line escape must land BEFORE the ◆ card header, so the header
      # never glues onto "thinking…".
      expect(out).to match(/thinking….*\r\e\[2K.*◆ Allow shell with args/m)
      expect(out).not_to include("thinking…◆")
    end

    it "finalizes an in-progress content stream before the approval card" do
      stub_choice(:once)
      out = capture_stdout do
        ui.stream(type: :content, text: "Let me run this.")
        ui.confirm("Allow shell with args?")
      end
      # The reasoning tail must be committed on its own line — the card header
      # never glues onto it ("Let me run this.◆ Allow…").
      expect(out).not_to include("Let me run this.◆")
      expect(out).to include("◆ Allow shell with args")
    end

    it "returns true for 'yes once' without remembering" do
      stub_choice(:once)
      capture_stdout { expect(ui.confirm("ok?", scope: "shell:ls")).to be(true) }
      expect(cache.allowed?("sess-1", "shell:ls")).to be(false)
    end

    # #110: the "this tool (this session)" option always existed but nothing
    # surfaced it — a multi-edit refactor interrupted on every call. The first
    # plain "Approve once" now prints a one-time tip naming it.
    it "tips the session-scope option once after the first 'Approve once' (#110)" do
      stub_choice(:once)
      first  = capture_stdout { ui.confirm("Allow edit?", scope: "edit:a", tool: "edit") }
      second = capture_stdout { ui.confirm("Allow edit?", scope: "edit:b", tool: "edit") }
      expect(first).to include(%(tip: choose "Approve — this tool (this session)"))
      expect(first).to include("for edit this session")
      expect(second).not_to include("tip:")
    end

    it "prints no session-scope tip on a deny (#110)" do
      stub_choice(:no)
      out = capture_stdout { ui.confirm("Allow edit?", scope: "edit:a", tool: "edit") }
      expect(out).not_to include("tip:")
    end

    it "prints no tip when the user already chose a session-wide grant (#110)" do
      stub_choice(:always_tool)
      out = capture_stdout { ui.confirm("Allow edit?", scope: "edit:a", tool: "edit") }
      expect(out).not_to include("tip:")
    end

    it "returns false for 'no'" do
      stub_choice(:no)
      capture_stdout { expect(ui.confirm("ok?", scope: "shell:ls")).to be(false) }
    end

    it "remembers the exact command scope on 'always this command'" do
      stub_choice(:always_command)
      capture_stdout { expect(ui.confirm("ok?", scope: "shell:ls")).to be(true) }
      expect(cache.allowed?("sess-1", "shell:ls")).to be(true)
      # A different command of the same tool is NOT covered.
      expect(cache.allowed?("sess-1", "shell:rm -rf /")).to be(false)
    end

    it "remembers the tool-wide scope on 'always this tool'" do
      stub_choice(:always_tool)
      capture_stdout { expect(ui.confirm("ok?", scope: "shell:ls")).to be(true) }
      expect(cache.allowed?("sess-1", "shell")).to be(true)
    end

    it "short-circuits a later identical call after 'always this command'" do
      prompt = stub_choice(:always_command)
      capture_stdout { ui.confirm("ok?", scope: "shell:ls") }

      # Second identical call must NOT prompt again.
      capture_stdout { expect(ui.confirm("ok?", scope: "shell:ls")).to be(true) }
      expect(prompt).to have_received(:select).once
    end

    it "short-circuits any command of a tool after 'always this tool'" do
      prompt = stub_choice(:always_tool)
      capture_stdout { ui.confirm("ok?", scope: "shell:ls") }

      # A DIFFERENT command of the same tool is covered by the tool-wide grant.
      capture_stdout { expect(ui.confirm("rm?", scope: "shell:rm -rf /")).to be(true) }
      expect(prompt).to have_received(:select).once
    end

    it "still prompts when no scope is given (legacy callers)" do
      prompt = stub_choice(:once)
      capture_stdout { ui.confirm("ok?") }
      capture_stdout { ui.confirm("ok?") }
      expect(prompt).to have_received(:select).twice
    end

    # --- S7: CLI scopes persist derived rules (parity with UI::API) ---

    it "persists the NARROW derived rule on 'always this command' (plain cmd)" do
      stub_choice(:always_command)
      expect(Rubino::Security::AllowlistPersister)
        .to receive(:persist).with("git status")
      capture_stdout do
        ui.confirm("ok?", scope: "shell:git status", tool: "shell", command: "git status")
      end
    end

    it "persists the PATTERN KEY on 'always this command' for a dangerous cmd" do
      _hit, key, desc = Rubino::Security::DangerousPatterns.detect("rm -rf /tmp/x")
      stub_choice(:always_command)
      expect(Rubino::Security::AllowlistPersister).to receive(:persist).with(key)
      capture_stdout do
        ui.confirm("ok?", scope: "shell:rm -rf /tmp/x", tool: "shell",
                          command: "rm -rf /tmp/x", pattern_key: key, description: desc)
      end
    end

    it "offers the prefix option and persists the PREFIX rule on 'always_prefix'" do
      prompt = stub_choice(:always_prefix)
      expect(Rubino::Security::AllowlistPersister).to receive(:persist).with("git")
      capture_stdout do
        ui.confirm("ok?", scope: "shell:git status", tool: "shell", command: "git status")
      end
      # The select menu was offered the prefix choice for a non-dangerous cmd.
      expect(prompt).to have_received(:select)
    end

    it "does NOT offer a prefix option for a dangerous command" do
      _hit, key, desc = Rubino::Security::DangerousPatterns.detect("rm -rf /tmp/x")
      offered = nil
      prompt = instance_double(TTY::Prompt)
      allow(prompt).to receive(:select) do |*, &blk|
        menu = double("menu")
        offered = []
        allow(menu).to receive(:choice) { |label, sym| offered << [label, sym] }
        blk.call(menu)
        :no
      end
      ui.instance_variable_set(:@prompt, prompt)
      capture_stdout do
        ui.confirm("ok?", scope: "shell:rm -rf /tmp/x", tool: "shell",
                          command: "rm -rf /tmp/x", pattern_key: key, description: desc)
      end
      expect(offered.map(&:last)).not_to include(:always_prefix)
    end

    it "shows the dangerous pattern description above the menu" do
      _hit, key, desc = Rubino::Security::DangerousPatterns.detect("rm -rf /tmp/x")
      stub_choice(:no)
      out = capture_stdout do
        ui.confirm("ok?", scope: "shell:rm -rf /tmp/x", tool: "shell",
                          command: "rm -rf /tmp/x", pattern_key: key, description: desc)
      end
      expect(out).to include(desc)
    end

    it "remembers the command across restarts has NO effect on 'always_tool' (CLI-only, not persisted)" do
      stub_choice(:always_tool)
      expect(Rubino::Security::AllowlistPersister).not_to receive(:persist)
      capture_stdout do
        ui.confirm("ok?", scope: "shell:ls", tool: "shell", command: "ls")
      end
      # always_tool stays an in-memory tool-wide grant.
      expect(cache.allowed?("sess-1", "shell")).to be(true)
    end

    it "always_tool is never a valid HTTP decision (CLI menu only)" do
      expect(Rubino::UI::API::APPROVE_DECISIONS).not_to include("always_tool")
      schema = Rubino::API::Schemas::DecideApproval
      expect(schema.call(decision: "always_tool")).to be_failure
      expect(schema.call(decision: "always_command")).to be_success
    end

    # --- deny semantics: one-off No vs persistent deny always ---

    it "plain No is one-off — denies, persists NO deny rule, leaves no session memory (re-prompts)" do
      stub_choice(:no)
      expect(Rubino::Security::DenyPersister).not_to receive(:persist)
      capture_stdout do
        expect(ui.confirm("ok?", scope: "shell:git status", tool: "shell", command: "git status")).to be(false)
      end
      # One-off: nothing cached, so a fresh confirm would prompt again.
      expect(cache.allowed?("sess-1", "shell:git status")).to be(false)
    end

    it "deny_always persists a PREFIX-scoped permissions:deny rule and returns false" do
      stub_choice(:deny_always)
      expect(Rubino::Security::DenyPersister).to receive(:persist).with("shell git*")
      capture_stdout do
        expect(ui.confirm("ok?", scope: "shell:git status", tool: "shell", command: "git status")).to be(false)
      end
    end

    it "deny_always persists the EXACT command for a dangerous cmd (no prefix derivable)" do
      _hit, key, desc = Rubino::Security::DangerousPatterns.detect("rm -rf /tmp/x")
      stub_choice(:deny_always)
      expect(Rubino::Security::DenyPersister).to receive(:persist).with("shell rm -rf /tmp/x")
      capture_stdout do
        ui.confirm("ok?", scope: "shell:rm -rf /tmp/x", tool: "shell",
                          command: "rm -rf /tmp/x", pattern_key: key, description: desc)
      end
    end

    # Off-by-one guard: assert the menu offers BOTH a distinct one-off No and a
    # separate deny_always, and that each LABEL maps to the intended symbol.
    it "maps menu labels to decisions correctly (No is one-off; deny always is separate)" do
      offered = nil
      prompt = instance_double(TTY::Prompt)
      allow(prompt).to receive(:select) do |*, &blk|
        menu = double("menu")
        offered = []
        allow(menu).to receive(:choice) { |label, sym| offered << [label, sym] }
        blk.call(menu)
        :no
      end
      ui.instance_variable_set(:@prompt, prompt)
      capture_stdout do
        ui.confirm("ok?", scope: "shell:git status", tool: "shell", command: "git status")
      end
      mapping = offered.to_h
      expect(mapping).to include("Deny once" => :no)
      expect(mapping).to include("Deny — this command (always)" => :deny_always)
      # The two denies are DISTINCT symbols (no off-by-one collapse).
      expect(mapping["Deny once"]).not_to eq(mapping["Deny — this command (always)"])
      expect(offered.map(&:last)).to include(:once, :no, :deny_always)
      # Labels are grammatically parallel: every line is a "<verb> — <scope>"
      # phrase; affirmatives all start with Approve, denies with Deny (#87).
      expect(offered.map(&:first)).to all(match(/\A(Approve|Deny)\b/))
    end
  end

  describe "#compression_started / #compression_finished" do
    it "renders compaction with `┄` bookends" do
      out = capture_stdout { ui.compression_started }
      expect(out).to include("┄ compacting context… ┄")
    end

    it "renders finished compaction with saved-tokens count" do
      out = capture_stdout { ui.compression_finished({ saved_tokens: 4200 }) }
      expect(out).to include("┄ compacted · saved 4200 tok ┄")
    end
  end

  describe "#activity_started / #activity_finished" do
    it "activity_started renders as a quiet ● row with optional hint" do
      out = capture_stdout { ui.activity_started("git", hint: "status") }
      expect(out).to include("● git status")
    end

    it "activity_finished renders as compact └ ✓ with optional metric" do
      out = capture_stdout { ui.activity_finished("git", metric: "clean") }
      expect(out).to include("└ ✓ clean")
    end

    it "activity_finished with failed: true renders as ✗ failed" do
      out = capture_stdout { ui.activity_finished("git", failed: true) }
      expect(out).to include("✗ failed · git")
    end

    # A multiline metric (e.g. a task_result body) used to be interpolated raw,
    # so everything after the first newline continued flush-left and unstyled.
    # It must collapse into ONE styled row, newlines joined as " — ".
    it "activity_finished inlines a newline-bearing metric into one styled row" do
      out = capture_stdout do
        ui.activity_finished("task_result", metric: "[sa_e488] status=completed\nreport line two")
      end
      lines = out.split("\n").reject(&:empty?)
      expect(lines.length).to eq(1)
      expect(lines.first).to include("[sa_e488] status=completed — report line two")
    end
  end

  describe "#approval_requested" do
    it "renders summary with ◆ prefix and choice keys" do
      out = capture_stdout do
        ui.approval_requested(
          summary: "Apply changes?",
          choices: [
            { key: "y", label: "apply" },
            { key: "n", label: "cancel" }
          ]
        )
      end
      expect(out).to include("◆ Apply changes?")
      expect(out).to include("[y] apply")
      expect(out).to include("[n] cancel")
    end
  end

  # #83: the danger annotation must be prominent (red+bold, not dim), and a
  # deny must visibly confirm the command was NOT executed.
  describe "#confirm" do
    before { ui.instance_variable_set(:@pastel, Pastel.new(enabled: true)) }

    it "renders the destructive-command warning in red + bold (not dim) — #83" do
      allow(ui).to receive(:approval_choice).and_return(:once)
      out = capture_stdout do
        ui.confirm("Allow shell with:", tool: "shell", command: "rm -rf /tmp/cache",
                                        description: "recursive delete")
      end
      expect(out).to include("⚠ recursive delete")
      # Pastel collapses red + bold into a single SGR sequence: ESC[31;1m.
      expect(out).to match(/\e\[31;1m  ⚠ recursive delete/) # red + bold
      expect(out).not_to match(/\e\[2m  ⚠/)                 # never dim
    end

    it "prints an explicit '✗ … denied — not executed' line on deny — #83" do
      allow(ui).to receive(:approval_choice).and_return(:no)
      out = capture_stdout do
        ui.confirm("Allow shell with:", tool: "shell", command: "rm -rf /tmp/cache")
      end
      expect(out).to include("✗")
      expect(out).to include("denied — not executed")
      expect(out).to match(/\e\[31m/) # red ✗, the same styling failed tools use
    end

    it "returns false on deny and true on approve — #83" do
      allow(ui).to receive(:approval_choice).and_return(:no)
      capture_stdout { expect(ui.confirm("Allow?", tool: "shell", command: "ls")).to be(false) }
      allow(ui).to receive(:approval_choice).and_return(:once)
      capture_stdout { expect(ui.confirm("Allow?", tool: "shell", command: "ls")).to be(true) }
    end

    it "does not print the denied line when the command is approved — #83" do
      allow(ui).to receive(:approval_choice).and_return(:once)
      out = capture_stdout do
        ui.confirm("Allow shell with:", tool: "shell", command: "ls")
      end
      expect(out).not_to include("not executed")
    end
  end

  # #111: a slash-command submit that interrupted a turn with nothing visibly
  # in flight (only a card animating) must not strand a `⎿ interrupted`
  # artifact above the command's own output. The suppression is one-shot.
  describe "#turn_interrupted quiet suppression (#111)" do
    it "swallows exactly ONE marker after suppress_interrupt_marker" do
      ui.suppress_interrupt_marker
      first  = capture_stdout { ui.turn_interrupted }
      second = capture_stdout { ui.turn_interrupted }
      expect(first).to eq("")
      expect(second).to include("⎿ interrupted")
    end

    it "can be reset at turn start so a stale suppression never leaks" do
      ui.suppress_interrupt_marker
      ui.suppress_interrupt_marker(value: false)
      out = capture_stdout { ui.turn_interrupted }
      expect(out).to include("⎿ interrupted")
    end
  end

  # #58: the /probe wait shows the SAME thinking row a normal turn gets. On a
  # bare TTY (idle prompt — no composer, so no $stdout.live seam) the animation
  # repaints in place via CR + clear-line; into a pipe it stays one static
  # print. #thinking_finished is the public clear for synchronous waits.
  describe "#thinking_started on a bare TTY (#58)" do
    it "animates in place via CR repaints, then clears on thinking_finished" do
      out = capture_stdout do
        allow($stdout).to receive(:tty?).and_return(true)
        ui.thinking_started
        sleep 0.25
        ui.thinking_finished
      end
      expect(out).to include("thinking")
      expect(out.scan("\r\e[2K").size).to be >= 2 # repaint frames + final clear
    end

    it "degrades to one static print into a pipe (never animates)" do
      out = capture_stdout do
        ui.thinking_started
        sleep 0.15
        ui.thinking_finished
      end
      expect(out.scan("thinking…").size).to eq(1)
    end
  end

  describe "#thinking_finished" do
    it "is a quiet no-op when nothing is showing" do
      out = capture_stdout { ui.thinking_finished }
      expect(out).to eq("")
    end
  end

  # #73: the /sessions picker advertises "(Esc to cancel)" — Esc must actually
  # cancel. The cancellable picker prompt binds :keyescape to the same
  # InputInterrupt Ctrl-C raises; #select rescues it to nil. tty-reader parses
  # whole escape sequences, so an arrow key (ESC [ B…) never trips the binding.
  describe "#select Esc cancel (#73)" do
    def picker_with_keys(keys)
      require "tty/prompt/test"
      test_prompt = TTY::Prompt::Test.new
      test_prompt.input << keys
      test_prompt.input.rewind
      allow(TTY::Prompt).to receive(:new).and_return(test_prompt)
      allow(ui).to receive(:interactive_terminal?).and_return(true)
    end

    let(:choices) { [["first", 1], ["second", 2]] }

    it "returns nil when the user presses Esc (the advertised cancel)" do
      picker_with_keys("\e")
      expect(ui.select("Resume which session? (Esc to cancel)", choices)).to be_nil
    end

    it "returns the highlighted value on Enter" do
      picker_with_keys("\r")
      expect(ui.select("pick", choices)).to eq(1)
    end

    it "does not mistake an arrow-key escape prefix for a cancel" do
      picker_with_keys("\e[B\r") # ↓ then Enter — selects the second row
      expect(ui.select("pick", choices)).to eq(2)
    end

    # Regression for #138: Esc aborts tty-prompt mid-render, parking the cursor
    # at the END of the last menu row — the caller's cancel hint then glued
    # straight onto it ("… · active)Resume: /sessions <id|title>"). The cancel
    # path must restore line discipline with a newline before returning.
    it "emits a newline on Esc so the next committed line never glues onto the last row (#138)" do
      picker_with_keys("\e")
      out = capture_stdout { expect(ui.select("pick", choices)).to be_nil }
      expect(out).to end_with("\n")
    end
  end

  describe "#mode_changed" do
    it "renders dim when entering non-yolo mode" do
      out = capture_stdout { ui.mode_changed(:plan) }
      expect(out).to include("┄ mode plan ┄")
    end

    it "renders yellow when entering yolo" do
      # Force Pastel ANSI output for non-TTY StringIO
      ui.instance_variable_set(:@pastel, Pastel.new(enabled: true))
      out = capture_stdout { ui.mode_changed(:yolo) }
      expect(out).to include("┄ mode yolo ┄")
      expect(out).to match(/\e\[33m/) # yellow
    end
  end
end
