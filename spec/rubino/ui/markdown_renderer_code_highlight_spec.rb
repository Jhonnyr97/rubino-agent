# frozen_string_literal: true

# Syntax highlighting of fenced code blocks (display.code_highlight, Rouge).
# Applied only on the COMMITTED render; unknown languages and any failure fall
# back to the plain code body, and highlighting is OFF by default.
RSpec.describe Rubino::UI::MarkdownRenderer do
  def flat(renderer, src)
    renderer.render(src).map { |line_tokens| line_tokens.map { |t, _s| t }.join }.join("\n")
  end

  let(:ruby_block) { "```ruby\ndef hi\n  puts 42\nend\n```" }

  it "emits ANSI color for a known language when code_highlight is on" do
    out = flat(described_class.new(width: 80, code_highlight: true), ruby_block)
    expect(out).to include("\e[38") # a 256-colour SGR from Rouge
    expect(out).to include("puts")  # the code is still present
  end

  it "does NOT highlight when code_highlight is off (default)" do
    out = flat(described_class.new(width: 80), ruby_block)
    expect(out).not_to include("\e[38;5")
    expect(out).to include("puts 42")
  end

  it "falls back to a plain body for an unknown language" do
    out = flat(described_class.new(width: 80, code_highlight: true),
               "```nosuchlang\nfoo bar\n```")
    expect(out).not_to include("\e[38;5")
    expect(out).to include("foo bar")
  end

  it "falls back to a plain body for a language-less fence" do
    out = flat(described_class.new(width: 80, code_highlight: true),
               "```\njust text\n```")
    expect(out).not_to include("\e[38;5")
    expect(out).to include("just text")
  end

  it "still draws the code box (gutter + frame) when highlighting" do
    out = flat(described_class.new(width: 80, code_highlight: true), ruby_block)
    expect(out).to include("┌").and include("│").and include("└")
  end

  it "resets color at each code line's end so no bleed into the next gutter" do
    out = described_class.new(width: 80, code_highlight: true).render(ruby_block)
    code_rows = out.select { |lt| lt.first&.first == "│ " }
    expect(code_rows).not_to be_empty
    code_rows.each { |row| expect(row.last.first).to end_with("\e[0m") }
  end
end
