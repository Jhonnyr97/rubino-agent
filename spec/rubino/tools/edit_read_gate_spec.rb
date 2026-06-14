# frozen_string_literal: true

# Edit and MultiEdit must refuse to write a file unless it was read in the
# current turn AND its mtime is unchanged since the read. The gate lives on
# the tool itself and is opt-in: if no ReadTracker is injected the tool
# behaves as before (unit-test ergonomics, single-shot MCP calls).
RSpec.describe "Read-before-Edit gate" do
  let(:tmp_dir) { Dir.mktmpdir("read-gate") }
  let(:tracker) { Rubino::Tools::ReadTracker.new }

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

  describe Rubino::Tools::EditTool do
    subject(:tool) do
      described_class.new.tap { |t| t.read_tracker = tracker }
    end

    it "refuses an edit on a file the tracker has not seen" do
      path = write_file("a.rb", "hello")
      out  = tool.call("file_path" => path, "old_string" => "hello", "new_string" => "world")
      msg  = out.is_a?(Hash) ? out[:output].to_s : out.to_s
      expect(msg).to start_with("Error: must use the read tool")
      expect(msg).to include("so the edit can verify")
      expect(File.read(path)).to eq("hello") # unchanged
    end

    it "allows an edit when the tracker has seen the file at its current mtime" do
      path = write_file("a.rb", "hello")
      tracker.register(path, File.mtime(path))
      out = tool.call("file_path" => path, "old_string" => "hello", "new_string" => "world")
      expect(out).to be_a(Hash)
      expect(File.read(path)).to eq("world")
    end

    it "refuses when the file's content changed on disk after the recorded read" do
      path = write_file("a.rb", "hello")
      tracker.register(path, File.mtime(path)) # records mtime + hash of "hello"
      File.write(path, "HELLO ON DISK") # someone else mutated it
      out = tool.call("file_path" => path, "old_string" => "hello", "new_string" => "world")
      msg = out.is_a?(Hash) ? out[:output].to_s : out.to_s
      expect(msg).to include("changed on disk since the last read")
      expect(msg).to include("so the edit reflect the current contents")
      expect(File.read(path)).to eq("HELLO ON DISK") # unchanged by the refused edit
    end

    it "does NOT trip the stale guard on a no-op touch (same bytes, newer mtime) — r5 B2" do
      path = write_file("a.rb", "hello")
      tracker.register(path, File.mtime(path))
      FileUtils.touch(path, mtime: File.mtime(path) + 10) # mtime bumped, bytes identical
      out = tool.call("file_path" => path, "old_string" => "hello", "new_string" => "world")
      expect(out).to be_a(Hash) # gate passed on content-hash match
      expect(File.read(path)).to eq("world")
    end

    it "is a no-op gate when no tracker is injected" do
      no_tracker = described_class.new
      path = write_file("a.rb", "hello")
      out  = no_tracker.call("file_path" => path, "old_string" => "hello", "new_string" => "world")
      expect(out).to be_a(Hash)
      expect(File.read(path)).to eq("world")
    end
  end

  describe Rubino::Tools::MultiEditTool do
    subject(:tool) do
      described_class.new.tap { |t| t.read_tracker = tracker }
    end

    it "refuses when the tracker has not seen the file" do
      path = write_file("b.rb", "one two three")
      out  = tool.call(
        "file_path" => path,
        "edits" => [{ "old_string" => "one", "new_string" => "1" }]
      )
      msg = out.is_a?(Hash) ? out[:output] : out.to_s
      expect(msg).to start_with("Error: must use the read tool")
      expect(msg).to include("so the edits can verify")
      expect(out[:error_code]).to eq(:stale_read) if out.is_a?(Hash)
      expect(File.read(path)).to eq("one two three")
    end

    it "allows when the tracker has seen the file at its current mtime" do
      path = write_file("b.rb", "one two three")
      tracker.register(path, File.mtime(path))
      out = tool.call(
        "file_path" => path,
        "edits" => [
          { "old_string" => "one", "new_string" => "1" },
          { "old_string" => "two", "new_string" => "2" }
        ]
      )
      expect(out).to include("Applied 2 edit(s)")
      expect(File.read(path)).to eq("1 2 three")
    end

    it "refuses when the file content changed on disk since the recorded read" do
      path = write_file("b.rb", "one")
      tracker.register(path, File.mtime(path))
      File.write(path, "ONE CHANGED")
      out = tool.call(
        "file_path" => path,
        "edits" => [{ "old_string" => "one", "new_string" => "1" }]
      )
      msg = out.is_a?(Hash) ? out[:output] : out.to_s
      expect(msg).to include("changed on disk since the last read")
      expect(msg).to include("so the edits reflect the current contents")
      expect(out[:error_code]).to eq(:stale_read) if out.is_a?(Hash)
      expect(File.read(path)).to eq("ONE CHANGED")
    end
  end

  describe "ReadTool fills the tracker" do
    it "registers the file's mtime so a follow-up Edit passes the gate" do
      path = write_file("c.rb", "alpha beta")
      reader = Rubino::Tools::ReadTool.new.tap { |t| t.read_tracker = tracker }
      reader.call("file_path" => path)

      editor = Rubino::Tools::EditTool.new.tap { |t| t.read_tracker = tracker }
      out = editor.call("file_path" => path, "old_string" => "alpha", "new_string" => "ALPHA")
      expect(out).to be_a(Hash)
      expect(File.read(path)).to eq("ALPHA beta")
    end
  end
end
