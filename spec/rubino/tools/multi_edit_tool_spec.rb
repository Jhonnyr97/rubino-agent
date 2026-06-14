# frozen_string_literal: true

RSpec.describe Rubino::Tools::MultiEditTool do
  subject(:tool) { described_class.new }

  let(:tmp_dir) { Dir.mktmpdir("multi_edit_spec") }
  let(:path)    { File.join(tmp_dir, "f.txt") }

  before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    FileUtils.rm_rf(tmp_dir)
  end

  it "applies multiple sequential edits" do
    File.write(path, "alpha beta gamma\n")
    out = tool.call(
      "file_path" => path,
      "edits" => [
        { "old_string" => "alpha", "new_string" => "ALPHA" },
        { "old_string" => "gamma", "new_string" => "GAMMA" }
      ]
    )
    expect(File.read(path)).to eq("ALPHA beta GAMMA\n")
    expect(out[:output]).to include("Applied 2 edit(s)")
  end

  it "renders a per-edit red/green diff body on success (F4/F5)" do
    File.write(path, "alpha beta gamma\n")
    out = tool.call(
      "file_path" => path,
      "edits" => [
        { "old_string" => "alpha", "new_string" => "ALPHA" },
        { "old_string" => "gamma", "new_string" => "GAMMA" }
      ]
    )
    expect(out[:body_kind]).to eq(:diff)
    expect(out[:body]).to include("- alpha").and include("+ ALPHA")
    expect(out[:body]).to include("- gamma").and include("+ GAMMA")
    expect(out[:metrics]).to include("2 edits").and include("2 replacements")
  end

  it "sees the result of prior edits inside the same call" do
    File.write(path, "old name\n")
    tool.call(
      "file_path" => path,
      "edits" => [
        { "old_string" => "old", "new_string" => "new" },
        { "old_string" => "new name", "new_string" => "renamed" }
      ]
    )
    expect(File.read(path)).to eq("renamed\n")
  end

  it "leaves the file untouched when any edit fails" do
    File.write(path, "alpha\n")
    out = tool.call(
      "file_path" => path,
      "edits" => [
        { "old_string" => "alpha", "new_string" => "ALPHA" },
        { "old_string" => "zeta",  "new_string" => "ZETA" }
      ]
    )
    expect(File.read(path)).to eq("alpha\n")
    expect(out).to include("edit #2")
    expect(out).to include("not found")
  end

  it "rejects ambiguous edits unless replace_all is set" do
    File.write(path, "x\nx\n")
    out = tool.call(
      "file_path" => path,
      "edits" => [{ "old_string" => "x", "new_string" => "y" }]
    )
    expect(out).to include("2 matches")
    expect(File.read(path)).to eq("x\nx\n")
  end

  it "honours replace_all" do
    File.write(path, "x\nx\n")
    tool.call(
      "file_path" => path,
      "edits" => [{ "old_string" => "x", "new_string" => "y", "replace_all" => true }]
    )
    expect(File.read(path)).to eq("y\ny\n")
  end

  it "errors on identical old/new" do
    File.write(path, "x\n")
    out = tool.call(
      "file_path" => path,
      "edits" => [{ "old_string" => "x", "new_string" => "x" }]
    )
    expect(out).to include("identical")
  end

  it "errors on empty edits" do
    File.write(path, "x\n")
    out = tool.call("file_path" => path, "edits" => [])
    expect(out).to include("non-empty array")
  end

  # HIGH-1: the tool's description advertises writing "atomically" — make it
  # true on the disk seam too. The single final write goes through
  # AtomicFile.write_atomic (temp + fsync + atomic rename) so a mid-write crash
  # can't leave a torn file.
  describe "crash-safe (atomic) write" do
    it "writes the staged result through Util::AtomicFile.write_atomic" do
      File.write(path, "alpha beta\n")
      expect(Rubino::Util::AtomicFile).to receive(:write_atomic)
        .with(path, "ALPHA beta\n").and_call_original
      tool.call("file_path" => path,
                "edits" => [{ "old_string" => "alpha", "new_string" => "ALPHA" }])
      expect(File.read(path)).to eq("ALPHA beta\n")
    end
  end
end
