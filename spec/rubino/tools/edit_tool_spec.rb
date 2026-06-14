# frozen_string_literal: true

RSpec.describe Rubino::Tools::EditTool do
  subject(:tool) { described_class.new }

  let(:tmp_dir) { Dir.mktmpdir("edit_tool_spec") }

  before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    FileUtils.rm_rf(tmp_dir)
  end

  def write_file(name, content)
    path = File.join(tmp_dir, name)
    File.write(path, content)
    path
  end

  it "has name 'edit'" do
    expect(tool.name).to eq("edit")
  end

  it "reports medium risk" do
    expect(tool.risk_level).to eq(:medium)
  end

  describe "successful replacement" do
    it "replaces the first occurrence of old_string with new_string" do
      path = write_file("test.rb", "def foo\n  1\nend\n")
      tool.call("file_path" => path, "old_string" => "1", "new_string" => "2")
      expect(File.read(path)).to include("2")
      expect(File.read(path)).not_to include("  1\n")
    end

    it "returns a confirmation message with replacement count" do
      path = write_file("a.txt", "hello world")
      result = tool.call("file_path" => path, "old_string" => "world", "new_string" => "ruby")
      expect(result[:output]).to include("1 replacement")
    end

    it "reports `N replacements · +A −R` metric for the done header" do
      path = write_file("a.txt", "hello world")
      result = tool.call("file_path" => path, "old_string" => "world", "new_string" => "ruby")
      expect(result[:metrics]).to eq("1 replacement · +1 −1")
    end

    it "replaces all occurrences when replace_all is true" do
      path = write_file("b.txt", "a a a")
      result = tool.call("file_path" => path, "old_string" => "a", "new_string" => "b", "replace_all" => true)
      expect(File.read(path)).to eq("b b b")
      expect(result[:output]).to include("3 replacement")
    end
  end

  describe "error cases" do
    it "returns error when file does not exist" do
      result = tool.call("file_path" => "/no/such/file.rb", "old_string" => "x", "new_string" => "y")
      expect(result).to include("Error")
    end

    it "returns error when old_string is not found in file" do
      path = write_file("c.txt", "hello")
      result = tool.call("file_path" => path, "old_string" => "not_here", "new_string" => "x")
      expect(result).to include("not found")
    end

    it "returns error when multiple matches exist and replace_all is false" do
      path = write_file("d.txt", "x x x")
      result = tool.call("file_path" => path, "old_string" => "x", "new_string" => "y")
      expect(result).to include("3 matches")
    end
  end

  # HIGH-1: an edit is a read-modify-write of an EXISTING file, so a mid-write
  # crash would destroy the user's original content. The fix routes the final
  # write through AtomicFile.write_atomic (temp + fsync + atomic rename).
  describe "crash-safe (atomic) write" do
    it "writes the result through Util::AtomicFile.write_atomic" do
      path = write_file("atomic.rb", "alpha\n")
      expect(Rubino::Util::AtomicFile).to receive(:write_atomic).with(path, "beta\n").and_call_original
      tool.call("file_path" => path, "old_string" => "alpha", "new_string" => "beta")
      expect(File.read(path)).to eq("beta\n")
    end
  end

  # #326 — a one-line ASCII edit on a file with non-UTF-8 (Latin-1) bytes on
  # OTHER lines must leave those other lines BYTE-IDENTICAL. The old code ran
  # `content.scrub` over the whole file before the sub and persisted the
  # scrubbed buffer, lossily rewriting `André`/`Zürich` to U+FFFD on untouched
  # lines. The fix reads/writes raw bytes so only the matched span changes.
  describe "byte-safe edit on an invalid-UTF-8 file (#326)" do
    it "leaves Latin-1 bytes on untouched lines identical after a one-line ASCII edit" do
      latin1 = +"name: André\ncity: Zürich\nport: 8080\n"
      latin1.encode!("ISO-8859-1") # raw Latin-1 é/ü bytes (0xE9 / 0xFC)
      path = File.join(tmp_dir, "config.txt")
      File.binwrite(path, latin1)

      original_bytes = File.binread(path)

      result = tool.call("file_path" => path, "old_string" => "8080", "new_string" => "9090")
      expect(result).to be_a(Hash) # success, not an error string

      after = File.binread(path)
      # The edited line changed…
      expect(after).to include("port: 9090".b)
      # …and the Latin-1 é/ü bytes on the other lines survived verbatim.
      head = original_bytes.index("port".b)
      expect(after.byteslice(0, head)).to eq(original_bytes.byteslice(0, head))
      expect(after.b).to include("Andr\xE9".b)
      expect(after.b).to include("Z\xFCrich".b)
    end
  end

  # #329a — an empty old_string with replace_all would inject new_string at
  # every char boundary and corrupt the file. Reject it.
  describe "empty old_string guard (#329a)" do
    it "refuses an edit with an empty old_string instead of corrupting the file" do
      path = write_file("guard.txt", "hello world")
      result = tool.call("file_path" => path, "old_string" => "", "new_string" => "X", "replace_all" => true)
      expect(result).to be_a(String)
      expect(result).to include("empty")
      expect(File.read(path)).to eq("hello world") # untouched
    end
  end

  # #329b — old_string == new_string changes nothing, so reporting "1
  # replacement applied" misleads the model. Reject it, like multi_edit.
  describe "no-op (identical strings) guard (#329b)" do
    it "rejects an edit whose old_string equals new_string" do
      path = write_file("noop.txt", "keep me")
      result = tool.call("file_path" => path, "old_string" => "keep", "new_string" => "keep")
      expect(result).to be_a(String)
      expect(result).to include("identical")
      expect(File.read(path)).to eq("keep me")
    end
  end
end
