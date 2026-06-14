# frozen_string_literal: true

RSpec.describe Rubino::Tools::WriteTool do
  subject(:tool) { described_class.new }

  def payload(result) = result.is_a?(Hash) ? result[:output] : result

  let(:tmp_dir) { Dir.mktmpdir("write_tool_spec") }

  before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    FileUtils.rm_rf(tmp_dir)
  end

  it "has name 'write' and :medium risk" do
    expect(tool.name).to eq("write")
    expect(tool.risk_level).to eq(:medium)
  end

  it "creates a new file and reports 'created'" do
    path = File.join(tmp_dir, "new.txt")
    out = payload(tool.call("file_path" => path, "content" => "hi"))
    expect(File.read(path)).to eq("hi")
    expect(out).to include("created")
  end

  it "overwrites existing files and reports 'overwrote'" do
    path = File.join(tmp_dir, "existing.txt")
    File.write(path, "old")
    out = payload(tool.call("file_path" => path, "content" => "new"))
    expect(File.read(path)).to eq("new")
    expect(out).to include("overwrote")
  end

  it "reports `N lines · KB` metric for the done header" do
    path = File.join(tmp_dir, "m.txt")
    res  = tool.call("file_path" => path, "content" => "a\nb\nc\n")
    expect(res[:metrics]).to eq("3 lines · 6B")
  end

  it "creates parent directories" do
    path = File.join(tmp_dir, "a", "b", "c.txt")
    tool.call("file_path" => path, "content" => "deep")
    expect(File.exist?(path)).to be true
  end

  it "errors out on missing file_path" do
    expect(tool.call("file_path" => "", "content" => "x")).to include("file_path is required")
  end

  # r5 MF-2 — read-before-overwrite guard. Blind `write` over an EXISTING file
  # the model never read this session would clobber content it can't see; new
  # files are unaffected.
  describe "read-before-overwrite guard" do
    subject(:tool) { described_class.new.tap { |t| t.read_tracker = tracker } }

    let(:tracker) { Rubino::Tools::ReadTracker.new }

    it "blocks overwriting an existing un-read file and leaves it intact" do
      path = File.join(tmp_dir, "exists.txt")
      File.write(path, "PRECIOUS")
      out = tool.call("file_path" => path, "content" => "clobber")
      expect(out).to be_a(Hash)
      expect(out[:error_code]).to eq(:unread_overwrite)
      expect(out[:output]).to include("refusing to overwrite")
      expect(File.read(path)).to eq("PRECIOUS") # untouched
    end

    it "allows creating a NEW file (no read required)" do
      path = File.join(tmp_dir, "brand_new.txt")
      out = payload(tool.call("file_path" => path, "content" => "fresh"))
      expect(out).to include("created")
      expect(File.read(path)).to eq("fresh")
    end

    it "allows overwriting once the file was read this session" do
      path = File.join(tmp_dir, "exists.txt")
      File.write(path, "old")
      Rubino::Tools::ReadTool.new.tap { |t| t.read_tracker = tracker }.call("file_path" => path)
      out = payload(tool.call("file_path" => path, "content" => "new"))
      expect(out).to include("overwrote")
      expect(File.read(path)).to eq("new")
    end

    it "blocks an overwrite when the read is stale (content changed on disk)" do
      path = File.join(tmp_dir, "exists.txt")
      File.write(path, "v1")
      Rubino::Tools::ReadTool.new.tap { |t| t.read_tracker = tracker }.call("file_path" => path)
      File.write(path, "v2 from elsewhere")
      out = tool.call("file_path" => path, "content" => "clobber")
      expect(out).to be_a(Hash)
      expect(out[:error_code]).to eq(:unread_overwrite)
      expect(File.read(path)).to eq("v2 from elsewhere")
    end
  end

  # Regression: a prompt-injected `file_path: "/etc/passwd"` used to be
  # silently expanded and written. The path is now rejected at the tool
  # boundary, before the approval prompt sees it.
  describe "workspace sandbox" do
    it "refuses to write outside the workspace root" do
      out = tool.call("file_path" => "/etc/passwd", "content" => "pwned")
      expect(out).to include("refusing to access")
      expect(File.read("/etc/passwd")).not_to include("pwned") if File.readable?("/etc/passwd")
    end

    it "refuses to write through ../../ traversal" do
      out = tool.call("file_path" => File.join(tmp_dir, "..", "escape.txt"), "content" => "x")
      expect(out).to include("refusing to access")
    end

    it "honours tools.workspace_strict=false (opt-out)" do
      Rubino.configuration.set("tools", "workspace_strict", false)
      escape = File.join(Dir.tmpdir, "rubino_escape_test.txt")
      begin
        out = payload(tool.call("file_path" => escape, "content" => "ok"))
        expect(out).to include("created").or include("overwrote")
        expect(File.read(escape)).to eq("ok")
      ensure
        File.delete(escape) if File.exist?(escape)
        Rubino.configuration.set("tools", "workspace_strict", true)
      end
    end
  end
end
