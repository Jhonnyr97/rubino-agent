# frozen_string_literal: true

# STRUCTURAL enforcement of the output funnel (CWE-150 defense by construction).
#
# The per-sink `sanitize_terminal` discipline was leaky: every new $stdout.puts
# had to REMEMBER to defang its interpolated text, and the ones that forgot
# became the escape-injection sinks (#563/#564/#565-568). The funnel
# (PrinterBase#emit / #emit_styled / #emit_glyph / #emit_frame) fixed that by
# making #write_line / #write_raw the ONLY place in the UI layer that writes to
# $stdout — both reachable only AFTER the text has been sanitized.
#
# This spec is the regression backstop that keeps it that way: it scans the UI
# source and FAILS if any file other than printer_base.rb writes to $stdout
# directly. A future sink that bakes untrusted text + colour into one string and
# prints it raw can no longer slip in unnoticed — the test goes red the moment
# the write is added, before it can become a CVE. It is the structural partner
# to the BEHAVIOURAL escape guards (output_funnel_spec / cli_escape_sinks_spec):
# those prove the funnel defangs and that no sink routes untrusted text through
# the wrong (SGR-preserving) path; this proves no un-funnelled sink can exist.
RSpec.describe Rubino::UI::PrinterBase do
  # The funnel's file: the single seam every other UI file must reach the
  # terminal THROUGH (committed lines via #emit/#emit_styled, transient frames
  # via #emit_frame) — never with its own $stdout write.
  let(:funnel_file) { "printer_base.rb" }
  let(:ui_dir) { File.expand_path("../../../lib/rubino/ui", __dir__) }

  # $stdout WRITE methods. Non-write uses ($stdout.tty?, .flush, .sync,
  # .respond_to?, and the `$stdout = proxy` swap) are legitimate and ignored —
  # only methods that emit BYTES can carry an un-defanged escape to the TTY.
  let(:write_call) do
    /\$stdout\s*\.\s*(?:puts|print|printf|write|write_nonblock|syswrite)\b|\$stdout\s*<</
  end

  # Strip the comment tail so the rdoc/comment mentions of "$stdout.print/puts"
  # in the funnel's own documentation don't count as call sites. A real call's
  # `$stdout.<write>` always precedes any `#` on its line (a `#{}` interpolation
  # opens AFTER the receiver+method), so cutting at the first `#` preserves every
  # genuine call while dropping full-line and inline comments.
  def offenders_in(path, pattern)
    File.readlines(path).each_with_index.filter_map do |line, i|
      code = line.split("#", 2).first.to_s
      "#{File.basename(path)}:#{i + 1}: #{line.strip}" if code.match?(pattern)
    end
  end

  it "writes to $stdout from NOWHERE in lib/rubino/ui except the funnel" do
    others = Dir.glob(File.join(ui_dir, "*.rb")).reject { |p| File.basename(p) == funnel_file }
    offenders = others.flat_map { |p| offenders_in(p, write_call) }

    expect(offenders).to be_empty, <<~MSG
      Found direct $stdout write(s) in the UI layer outside the funnel
      (#{funnel_file}). Route the text through PrinterBase#emit (untrusted),
      #emit_styled (rubino's own SGR), #emit_glyph (trusted glyph + untrusted
      body), or #emit_frame (rubino cursor-control frame) instead — that is what
      keeps the CWE-150 defense structural. Offending lines:
        #{offenders.join("\n  ")}
    MSG
  end

  it "still has the funnel's two seams in printer_base.rb (the guard isn't vacuous)" do
    # #write_line ($stdout.puts) and #write_raw ($stdout.print) — the two and
    # only sanctioned writes. If these vanish the funnel was gutted; fail loudly
    # so the enforcement above can't pass simply because nothing writes anywhere.
    funnel = offenders_in(File.join(ui_dir, funnel_file), write_call)
    expect(funnel).not_to be_empty
  end
end
