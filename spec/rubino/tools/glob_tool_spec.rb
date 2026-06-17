# frozen_string_literal: true

RSpec.describe Rubino::Tools::GlobTool do
  subject(:tool) { described_class.new }

  # Successful glob returns a {output:, metrics:, body:, body_kind:} Hash so
  # the UI can render the box (metrics on done border, body inside). The
  # not-found and error paths still return a plain String. These specs
  # check the textual content either way, so unwrap when needed.
  def payload(result)
    result.is_a?(Hash) ? (result[:output] || result["output"]) : result
  end

  let(:tmp_dir) { Dir.mktmpdir("glob_tool_spec") }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    FileUtils.rm_rf(tmp_dir)
  end

  before do
    # glob is now workspace-sandboxed (r5 MF-1): root the workspace at tmp_dir
    # so these fixtures are inside it. Out-of-workspace has its own example.
    Rubino.configuration.set("terminal", "cwd", tmp_dir)
    File.write(File.join(tmp_dir, "foo.rb"), "")
    File.write(File.join(tmp_dir, "bar.rb"), "")
    File.write(File.join(tmp_dir, "readme.md"), "")
    subdir = File.join(tmp_dir, "lib")
    Dir.mkdir(subdir)
    File.write(File.join(subdir, "nested.rb"), "")
  end

  it "has name 'glob'" do
    expect(tool.name).to eq("glob")
  end

  it "has :low risk level" do
    expect(tool.risk_level).to eq(:low)
  end

  it "finds files matching a pattern" do
    result = payload(tool.call("pattern" => "*.rb", "path" => tmp_dir))
    expect(result).to include("foo.rb")
    expect(result).to include("bar.rb")
    expect(result).not_to include("readme.md")
  end

  it "finds nested files with ** pattern" do
    result = payload(tool.call("pattern" => "**/*.rb", "path" => tmp_dir))
    expect(result).to include("nested.rb")
  end

  it "respects max_results limit" do
    result = payload(tool.call("pattern" => "*.rb", "path" => tmp_dir, "max_results" => 1))
    # Header says "1 file(s) found:" — check that exactly 1 file is listed
    expect(result).to match(/^1 file/)
  end

  it "returns a message when no files match" do
    result = tool.call("pattern" => "*.xyz", "path" => tmp_dir)
    expect(result).to include("No files matched")
  end

  it "returns an error for a non-existent directory inside the workspace" do
    result = payload(tool.call("pattern" => "*.rb", "path" => File.join(tmp_dir, "no_such_dir")))
    expect(result).to include("Directory not found")
  end

  # #406: reads are BROAD now. glob resolves a path OUTSIDE the workspace and
  # lists matches; it only lists PATHS (no content) so there is no denylist.
  it "globs a directory OUTSIDE the workspace (reads broad, #406)" do
    outside = Dir.mktmpdir("glob_outside")
    File.write(File.join(outside, "ext.rb"), "x")
    result = payload(tool.call("pattern" => "*.rb", "path" => outside))
    expect(result).to include("ext.rb")
  ensure
    FileUtils.rm_rf(outside)
  end

  # #375c — glob ignored .gitignore entirely, surfacing node_modules / build
  # artifacts / ignored files that grep's rg path never would. It now honors
  # .gitignore by default, with an explicit include_ignored escape hatch.
  describe "honors .gitignore (#375c)" do
    let(:repo_dir) { Dir.mktmpdir("glob_ignore") }

    before do
      skip "git not installed" unless system("which git > /dev/null 2>&1")
      Dir.chdir(repo_dir) do
        system("git", "init", "-q", out: File::NULL, err: File::NULL)
        system("git", "config", "user.email", "t@t", out: File::NULL, err: File::NULL)
        system("git", "config", "user.name", "t", out: File::NULL, err: File::NULL)
      end
      File.write(File.join(repo_dir, ".gitignore"), "build.rb\n")
      File.write(File.join(repo_dir, "keep.rb"), "")
      File.write(File.join(repo_dir, "build.rb"), "")
      Rubino.configuration.set("terminal", "cwd", repo_dir)
    end

    after { FileUtils.rm_rf(repo_dir) }

    it "excludes git-ignored files by default" do
      result = payload(tool.call("pattern" => "*.rb", "path" => repo_dir))
      expect(result).to include("keep.rb")
      expect(result).not_to include("build.rb")
    end

    it "includes ignored files when include_ignored is set" do
      result = payload(tool.call("pattern" => "*.rb", "path" => repo_dir, "include_ignored" => true))
      expect(result).to include("keep.rb")
      expect(result).to include("build.rb")
    end
  end
end
