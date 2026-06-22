# frozen_string_literal: true

require "stringio"

# CWE-150 (#565-568) — the LAST batch of terminal escape-injection sinks in the
# CLI render seams. Each prints attacker-influenceable text (a probe answer, the
# committed reasoning, the open-fence fallback dump, a session title) into an
# interpolated, @pastel-wrapped row. A raw `\e[2J` (clear screen) / `\e]0;…\a`
# (set window title) / bare CR (line-rewind spoof) / BEL there reaches the
# emulator and EXECUTES. The CLI now routes the untrusted body through #safe
# (Util::Output.sanitize_terminal) BEFORE it is wrapped in rubino's own styling.
RSpec.describe Rubino::UI::CLI do
  subject(:ui) { described_class.new }

  # Under a non-TTY StringIO capture Pastel auto-disables colour, so a sink's
  # OWN @pastel SGR would be absent for a reason unrelated to sanitization.
  # Force colour ON so we can prove the trusted SGR wrapper SURVIVES alongside
  # the defanged untrusted body (the whole point: sanitize the body, keep ours).
  before { ui.instance_variable_set(:@pastel, Pastel.new(enabled: true)) }

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  # A clear-screen + bg-color + window-title cocktail, a BEL, and a CR
  # line-rewind spoof. KEEP-ME is legit text that must survive verbatim.
  def pwn = "KEEP-ME\e[2J\e]0;PWNED\arewind\rtail"

  # The shared contract every sink must satisfy after sanitization:
  # - no RAW control bytes leak (ESC / BEL / CR);
  # - the attacker's specific sequences are gone;
  # - the stripped ESC shows as caret notation (`^[`) so deletion isn't silent;
  # - legit text survives;
  # - rubino's OWN @pastel SGR styling is still present (dim is `\e[2m`).
  def expect_neutralized(out, expect_sgr: true)
    expect(out).not_to include("\e[2J")     # no clear-screen
    expect(out).not_to include("\e]0;")     # no window-title set
    expect(out).not_to include("\a")        # no raw BEL
    expect(out).not_to include("\r")        # no raw CR rewind
    expect(out).to include("KEEP-ME")       # legit text survives
    expect(out).to include("^[")            # stripped ESC rendered as caret
    expect(out).to include("\e[2m") if expect_sgr # our own dim SGR survives
  end

  describe "#probe_aside neutralizes the probe answer body (#565)" do
    it "defangs escapes but keeps the text and our dim styling" do
      out = capture_stdout { ui.probe_aside(pwn) }
      expect_neutralized(out)
    end
  end

  describe "#branch_confirmation neutralizes the session title (#568)" do
    it "defangs escapes carried in the title" do
      out = capture_stdout do
        ui.branch_confirmation(new_id: "n123", parent_id: "p456",
                               title: pwn, included_probe: false)
      end
      expect_neutralized(out)
    end
  end

  describe "committed reasoning neutralizes the model output (#566)" do
    # #566a — the streamed-block path (#reasoning_aside_lines returns the lines).
    it "defangs escapes in #reasoning_aside_lines and keeps dim styling" do
      out = ui.send(:reasoning_aside_lines, pwn).join("\n")
      expect_neutralized(out)
    end

    # #566b — the all-at-once aside (#commit_reasoning_aside prints to stdout).
    it "defangs escapes in #commit_reasoning_aside" do
      out = capture_stdout { ui.send(:commit_reasoning_aside, pwn, 2) }
      expect_neutralized(out)
    end
  end

  describe "#flush_content_stream open-fence fallback neutralizes the dump (#567)" do
    it "defangs escapes when a half-open fence is emitted as plain lines" do
      # Drive the real stream buffer into an open-fence state, then flush: the
      # buffered (RAW) text is dumped as margined plain lines (the #567 branch).
      ui.instance_variable_set(:@stream_md, Rubino::UI::StreamingMarkdown.new)
      ui.instance_variable_get(:@stream_md).feed("```\n#{pwn}")
      out = capture_stdout { ui.send(:flush_content_stream) }
      # This branch emits PLAIN margined lines (no @pastel wrapper), so no SGR.
      expect_neutralized(out, expect_sgr: false)
    end
  end

  # NOTE: a structural source-scan guard was attempted (flag any @pastel/
  # MD_MARGIN row interpolating a known-untrusted var without a `safe(` call on
  # the same line) and DROPPED. The generic body-var name `line` is reused at
  # both genuinely-untrusted sinks (the four fixed here) AND at trusted seams —
  # e.g. cli.rb #turn_footer assembles `line` from a rubino-built summary, and
  # #commit_markdown_block / #margined_render interpolate `line` that is
  # render_markdown_block OUTPUT (sanitized upstream). A regex cannot tell
  # "sanitized upstream / trusted-assembled" from "raw untrusted", so the scan
  # false-positived on those trusted rails (and missed multi-interp lines). The
  # four per-sink specs above are the concrete guard; each fixed sink in cli.rb
  # carries an inline CWE-150 comment documenting why `safe(...)` is required.
end
