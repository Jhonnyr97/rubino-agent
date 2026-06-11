# frozen_string_literal: true

RSpec.describe Rubino::UI::IndentedIO do
  subject(:io) { described_class.new(io: sink) }

  let(:sink) { StringIO.new }

  it "indents the first visible character of every line" do
    io.print("approve?\n‣ Approve once\n  Deny once\n")
    expect(sink.string).to eq("  approve?\n  ‣ Approve once\n    Deny once\n")
  end

  it "tracks line starts ACROSS writes" do
    io.print("approve?")
    io.print(" (press Enter)\n")
    io.print("‣ choice")
    expect(sink.string).to eq("  approve? (press Enter)\n  ‣ choice")
  end

  it "treats a cursor column-reset escape as a line start (repaint frames)" do
    io.print("\e[2K\e[1Gredrawn row")
    expect(sink.string).to eq("\e[2K\e[1G  redrawn row")
  end

  it "passes other escape sequences through without indenting them" do
    io.print("\e[A\e[2K")
    expect(sink.string).to eq("\e[A\e[2K")
    io.print("text")
    expect(sink.string).to eq("\e[A\e[2K  text")
  end

  it "handles a bare #puts as a newline" do
    io.puts
    io.print("next")
    expect(sink.string).to eq("\n  next")
  end

  it "delegates IO interrogation to the underlying handle" do
    expect(io.tty?).to eq(sink.tty?)
    expect(io.respond_to?(:sync)).to be(true)
  end
end
