# frozen_string_literal: true

# #41: error/notice lines after the ✗ glyph used a mix of "Unknown command",
# "unknown mode", "No background subagent"… — one convention now applies:
# LOWERCASE after the glyph. PrinterBase#error prefixes every message with
# "✗ ", so the rule is enforced where the text is born: any literal message
# handed to `.error("…")` (or written as a literal "✗ …" string) must not
# start with a sentence-cased word. ALL-CAPS tokens (env vars, acronyms like
# "TLS handshake…") are allowed — only an Uppercase-then-lowercase first word
# trips the guard. Cheap drift protection: greps the source, no runtime.
RSpec.describe Rubino::UI::PrinterBase do
  # The lib tree the guard scans.
  let(:lib_dir) { File.expand_path("../../lib", __dir__) }

  # A literal string argument to `.error(` starting with a sentence-cased word
  # ("Unknown …"), in either the "…" or %(…) form.
  let(:error_literal_re) { /\.error\(\s*(?:%\(|")([A-Z][a-z])/ }

  # A literal ✗ glyph followed directly by a sentence-cased word.
  let(:glyph_literal_re) { /✗ ([A-Z][a-z])/ }

  it "starts every literal ✗/error message lowercase" do
    offenders = []
    Dir[File.join(lib_dir, "**", "*.rb")].each do |path|
      File.readlines(path).each_with_index do |line, i|
        next if line.strip.start_with?("#") # comments may quote anything

        if line.match?(error_literal_re) || line.match?(glyph_literal_re)
          offenders << "#{path.sub("#{lib_dir}/", "lib/")}:#{i + 1}: #{line.strip}"
        end
      end
    end

    expect(offenders).to be_empty, <<~MSG
      ✗ error lines must start lowercase after the glyph (#41); fix:
      #{offenders.join("\n")}
    MSG
  end
end
