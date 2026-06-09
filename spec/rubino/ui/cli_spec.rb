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
  ACTIVITY_START = /● running/
  ACTIVITY_DONE  = /✓ done/
  ACTIVITY_FAIL  = /✗ done/

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

    it "ctrl-o reveal is a no-op when nothing is retained" do
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
        expect(live.string).to include("thinking…")
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
      expect(live_io.live_calls).to include("incomplete ta")
    end

    it "shows only the in-progress row of a partial table on the live seam" do
      # Regression: a half-arrived table was sent WHOLE to the one-row live
      # region, which collapsed its rows onto one line and clipped it with a
      # leading ellipsis. The live seam must receive only the in-progress row;
      # the earlier rows stay buffered until the table completes and renders.
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

      expect(live_io.live_calls.last).to eq("| ruby_llm | LLM")
      expect(live_io.live_calls).to all(satisfy { |s| !s.include?("\n") })
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
    it "renders as compact '● running name · hint'" do
      out = capture_stdout do
        ui.tool_started("shell", arguments: { command: "ls" })
      end
      expect(out).to include("● running  shell · ls")
      expect(out).not_to include("┌─")
    end

    it "renders as '● running name' when no args given" do
      out = capture_stdout { ui.tool_started("ping", arguments: nil) }
      expect(out).to include("● running  ping")
      expect(out).not_to match(/· \S/)
    end

    it "truncates long arg hints with an ellipsis" do
      long = "x" * 200
      expect { ui.tool_started("shell", arguments: { command: long }) }
        .to output(/\.\.\./).to_stdout
    end
  end

  describe "#tool_finished" do
    it "renders as '✓ done · name' on success" do
      out = capture_stdout do
        ui.tool_started("shell", arguments: { command: "ls" })
        ui.tool_finished("shell", result: nil)
      end
      expect(out).to include("✓ done · shell")
    end

    it "renders as '✗ done · name' on failure" do
      result = double("Result", success?: false, truncated_preview: "error")
      out = capture_stdout do
        ui.tool_started("shell", arguments: nil)
        ui.tool_finished("shell", result: result)
      end
      expect(out).to include("✗ done · shell")
    end

    it "shows metric on success when result provides it" do
      result = double("Result", truncated_preview: "42 files", success?: true, metrics: nil)
      out = capture_stdout do
        ui.tool_started("ls", arguments: nil)
        ui.tool_finished("ls", result: result)
      end
      expect(out).to include("✓ done · ls · 42 files")
    end

    it "shows error message on failure" do
      result = double("Result", success?: false, truncated_preview: "not found")
      out = capture_stdout do
        ui.tool_started("read", arguments: nil)
        ui.tool_finished("read", result: result)
      end
      expect(out).to include("✗ done · read · not found")
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
      expect(out).to include("✗ done · read")
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

  describe "#note" do
    it "renders a free line wrapped in `┄` bookends" do
      expect { ui.note("turn · 9s · 0 tools · 1.3k tok") }
        .to output(/┄ turn · 9s · 0 tools · 1\.3k tok ┄/).to_stdout
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
        ui.assistant_text("the answer")
      end
      # The erase-line sequence is emitted before the committed answer.
      expect(out).to match(/thinking….*\r\e\[2K.*the answer/m)
    end

    it "clears the indicator before a tool activity row" do
      out = capture_stdout do
        ui.thinking_started
        ui.tool_started("shell", arguments: { command: "ls" })
      end
      expect(out).to match(/thinking….*\r\e\[2K.*● running/m)
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
    it "activity_started renders as ● running with optional hint" do
      out = capture_stdout { ui.activity_started("git", hint: "status") }
      expect(out).to include("● running  git · status")
    end

    it "activity_finished renders as ✓ done with optional metric" do
      out = capture_stdout { ui.activity_finished("git", metric: "clean") }
      expect(out).to include("✓ done · git · clean")
    end

    it "activity_finished with failed: true renders as ✗ done" do
      out = capture_stdout { ui.activity_finished("git", failed: true) }
      expect(out).to include("✗ done · git")
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
