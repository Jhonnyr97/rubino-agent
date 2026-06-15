# frozen_string_literal: true

RSpec.describe Rubino::Tools::GrepTool do
  subject(:tool) { described_class.new }

  # Successful searches return a {output:, metrics:, body:, body_kind:} Hash
  # so the UI can render the box (metrics on done border, body inside).
  # Failure/empty paths still return a plain String. These specs check the
  # textual content either way, so unwrap when needed.
  def payload(result)
    result.is_a?(Hash) ? (result[:output] || result["output"]) : result
  end

  let(:tmp_dir) { Dir.mktmpdir("grep_tool_spec") }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    FileUtils.rm_rf(tmp_dir)
  end

  before do
    # grep is now workspace-sandboxed (r5 MF-1): root the workspace at tmp_dir
    # so these fixtures are inside it. Out-of-workspace has its own example.
    Rubino.configuration.set("terminal", "cwd", tmp_dir)
    File.write(File.join(tmp_dir, "alpha.rb"), "def hello\n  puts 'world'\nend\n")
    File.write(File.join(tmp_dir, "beta.rb"), "def goodbye\n  puts 'bye'\nend\n")
    File.write(File.join(tmp_dir, "notes.txt"), "remember to fix the hello bug")
  end

  it "has name 'grep'" do
    expect(tool.name).to eq("grep")
  end

  it "has :low risk level" do
    expect(tool.risk_level).to eq(:low)
  end

  it "finds files containing the pattern" do
    result = payload(tool.call("pattern" => "hello", "path" => tmp_dir))
    expect(result).to include("alpha.rb")
  end

  it "does not return files that do not match" do
    result = payload(tool.call("pattern" => "hello", "path" => tmp_dir))
    expect(result).not_to include("beta.rb")
  end

  it "filters by include pattern" do
    # 'hello' appears in both alpha.rb AND notes.txt
    result = payload(tool.call("pattern" => "hello", "path" => tmp_dir, "include" => "*.rb"))
    expect(result).to include("alpha.rb")
    expect(result).not_to include("notes.txt")
  end

  it "respects max_results limit" do
    result = payload(tool.call("pattern" => "puts", "path" => tmp_dir, "max_results" => 1))
    # The header says "N match(es)" so count carefully
    expect(result).to include("match")
  end

  it "caps a pattern that matches many lines and flags the overflow" do
    # A pattern matching every line of one big file would otherwise dump
    # thousands of lines (prod failure mode); the total cap bounds it.
    File.write(File.join(tmp_dir, "big.txt"), Array.new(500) { |i| "line #{i}" }.join("\n"))
    result = payload(tool.call("pattern" => "line", "path" => tmp_dir, "max_results" => 10))
    body   = result.sub(/\A.*?:\n\n/m, "") # strip the header
    expect(body.lines.size).to eq(10)
    expect(result).to match(/more.*raise max_results/)
  end

  it "returns a 'no matches' message when nothing is found" do
    result = tool.call("pattern" => "zzz_not_here", "path" => tmp_dir)
    expect(result).to include("No matches")
  end

  it "returns an error for a non-existent path inside the workspace" do
    result = payload(tool.call("pattern" => "x", "path" => File.join(tmp_dir, "no_such_dir")))
    expect(result).to include("Path not found")
  end

  it "reports an out-of-workspace path as outside the workspace, not missing (r5 MF-1)" do
    result = tool.call("pattern" => "x", "path" => "/no/such/dir")
    expect(result).to be_a(Hash)
    expect(result[:error_code]).to eq(:outside_workspace)
    expect(result[:output]).to include("outside your workspace")
    expect(result[:output]).not_to include("not found")
  end

  describe "grepping a single file (Bug B)" do
    it "accepts a file path and returns matching lines" do
      file   = File.join(tmp_dir, "alpha.rb")
      result = payload(tool.call("pattern" => "hello", "path" => file))
      expect(result).to include("hello")
      expect(result).not_to include("goodbye")
    end

    it "finds matches in a single file via the Ruby fallback" do
      allow(tool).to receive(:ripgrep_available?).and_return(false)
      file   = File.join(tmp_dir, "alpha.rb")
      result = payload(tool.call("pattern" => "hello", "path" => file))
      expect(result).to include("alpha.rb")
      expect(result).to include("hello")
    end
  end

  # #375a — the rg path buffered ALL of rg's output (IO.popen(argv).read) then
  # `.first(max_results)`: a pattern matching a huge file allocated +100MB just
  # to return 50 lines. It now streams the pipe and stops after max_results.
  describe "ripgrep streaming cap (#375a)" do
    before do
      skip "ripgrep not installed" unless system("which rg > /dev/null 2>&1")
      # A file with FAR more matches than max_results.
      File.write(File.join(tmp_dir, "many.txt"), Array.new(5_000) { |i| "match #{i}" }.join("\n"))
    end

    it "returns at most max_results lines and flags that more exist" do
      result = tool.call("pattern" => "match", "path" => tmp_dir, "max_results" => 10)
      out    = payload(result)
      match_lines = out.lines.grep(/many\.txt:/)
      expect(match_lines.size).to eq(10)
      expect(out).to include("more")
      expect(result[:metrics]).to include("+")
    end

    it "stops reading the rg pipe early instead of buffering all output" do
      # The regression was IO.popen(...).read (whole-pipe slurp). Spy that the
      # implementation never calls #read on the pipe.
      io_double = nil
      allow(IO).to receive(:popen).and_wrap_original do |orig, *args, **kw, &blk|
        orig.call(*args, **kw) do |io|
          io_double = io
          allow(io).to receive(:read).and_call_original
          blk.call(io)
        end
      end
      tool.call("pattern" => "match", "path" => tmp_dir, "max_results" => 5)
      expect(io_double).not_to have_received(:read)
    end
  end

  # #375b — the rg path honors .gitignore but the Ruby fallback used a bare
  # Dir.glob("**/*"), so the two returned DIFFERENT sets depending on whether rg
  # was installed (non-deterministic; leaked ignored content). Both must apply
  # the same ignore filter.
  describe "rg / fallback ignore consistency (#375b)" do
    let(:repo_dir) { Dir.mktmpdir("grep_ignore") }

    before do
      skip "ripgrep not installed" unless system("which rg > /dev/null 2>&1")
      skip "git not installed" unless system("which git > /dev/null 2>&1")
      Dir.chdir(repo_dir) do
        system("git", "init", "-q", out: File::NULL, err: File::NULL)
        system("git", "config", "user.email", "t@t", out: File::NULL, err: File::NULL)
        system("git", "config", "user.name", "t", out: File::NULL, err: File::NULL)
      end
      File.write(File.join(repo_dir, ".gitignore"), "ignored.rb\n")
      File.write(File.join(repo_dir, "tracked.rb"), "needle here\n")
      File.write(File.join(repo_dir, "ignored.rb"), "needle here\n")
      Rubino.configuration.set("terminal", "cwd", repo_dir)
    end

    after do
      Rubino.configuration.set("terminal", "cwd", nil)
      FileUtils.rm_rf(repo_dir)
    end

    # The two paths format the leading path differently (rg relative, the Ruby
    # fallback absolute) — an independent cosmetic difference. #375b is about
    # the ignore-filtered SET being identical, so compare by basename.
    def matched_files(result)
      payload(result).lines.grep(/needle/)
                     .map { |l| File.basename(l.split(":").first.to_s.strip) }
                     .uniq.sort
    end

    it "returns the same ignore-filtered file set for rg and the Ruby fallback" do
      allow(tool).to receive(:ripgrep_available?).and_return(true)
      rg_files = matched_files(tool.call("pattern" => "needle", "path" => repo_dir))

      allow(tool).to receive(:ripgrep_available?).and_return(false)
      ruby_files = matched_files(tool.call("pattern" => "needle", "path" => repo_dir))

      expect(rg_files).to eq(ruby_files)
      expect(rg_files).to include("tracked.rb")
      expect(rg_files).not_to include("ignored.rb")
    end
  end
end
