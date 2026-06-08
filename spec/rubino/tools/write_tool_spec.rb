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
