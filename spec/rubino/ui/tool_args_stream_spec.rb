# frozen_string_literal: true

RSpec.describe Rubino::UI::ToolArgsStream do
  subject(:stream) { described_class.new }

  # Feed the whole JSON in one shot, then flush; returns the full decoded text.
  def decode_all(json)
    out = stream.feed(json)
    out + stream.flush
  end

  it "surfaces a value, dropping the key and JSON structure" do
    expect(decode_all('{"path": "demo.py"}')).to eq("demo.py\n")
  end

  it "unescapes \\n into real newlines and returns complete lines from #feed" do
    out = stream.feed('{"content": "line1\nline2\n')
    expect(out).to eq("line1\nline2\n") # both complete lines released
  end

  it "holds the partial last line until its newline lands" do
    expect(stream.feed('{"content": "half')).to eq("") # no newline yet → nothing
    expect(stream.feed(' done\nrest')).to eq("half done\n")
    expect(stream.flush).to eq("rest")
  end

  it "emits each value on its own line (path then content for a write)" do
    json = '{"path": "a.py", "content": "x = 1\ny = 2"}'
    expect(decode_all(json)).to eq("a.py\nx = 1\ny = 2\n")
  end

  it "decodes escaped quotes and backslashes inside a value" do
    expect(decode_all('{"content": "say \\"hi\\" \\\\ ok"}')).to eq(%(say "hi" \\ ok\n))
  end

  it "decodes a \\uXXXX escape split across fragments" do
    stream.feed('{"content": "smile \\u26')
    out = stream.feed('03 !"}')
    expect(out + stream.flush).to eq("smile ☃ !\n")
  end

  it "carries a lone trailing backslash to the next fragment" do
    expect(stream.feed('{"content": "a\\')).to eq("")
    expect(stream.feed('nb"}')).to eq("a\nb\n")
  end

  it "ignores keys even when arguments arrive one character at a time" do
    json = '{"path":"f","content":"hi"}'
    out = +""
    json.each_char { |c| out << stream.feed(c) }
    expect(out + stream.flush).to eq("f\nhi\n")
  end
end
