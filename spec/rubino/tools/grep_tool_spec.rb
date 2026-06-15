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

  # #406: reads are BROAD now (Hermes/Claude/Codex parity). grep resolves a
  # path OUTSIDE the workspace and searches it; a genuinely missing path still
  # reports "Path not found".
  it "searches a directory OUTSIDE the workspace (reads broad, #406)" do
    outside = Dir.mktmpdir("grep_outside")
    File.write(File.join(outside, "ext.rb"), "def hello_external\nend\n")
    result = payload(tool.call("pattern" => "hello_external", "path" => outside))
    expect(result).to include("ext.rb")
  ensure
    FileUtils.rm_rf(outside)
  end

  it "still reports a genuinely missing path as not found" do
    result = tool.call("pattern" => "x", "path" => "/no/such/dir")
    expect(payload(result)).to include("Path not found")
  end

  # #406 secret denylist (defense-in-depth, NOT a hard boundary).
  it "refuses to grep a .env credential file directly" do
    outside = Dir.mktmpdir("grep_secret")
    File.write(File.join(outside, ".env"), "API_KEY=supersecret\n")
    result = tool.call("pattern" => "KEY", "path" => File.join(outside, ".env"))
    expect(result).to be_a(Hash)
    expect(result[:error_code]).to eq(:secret_denied)
    expect(result[:output]).not_to include("supersecret")
  ensure
    FileUtils.rm_rf(outside)
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

  # #391 (regression of #375) — on a large match-heavy file, the streaming early
  # `io.close` (SIGPIPE after the cap) makes rg exit status 1 (broken pipe) on
  # some platforms. The recovery `status = 0 if lines.any? && status != 1`
  # EXCLUDED status 1, so the deliberate early-close fell into the `status == 1 →
  # "No matches"` branch and DROPPED the matches already collected. The fix
  # treats a cap-hit-with-matches (more_exist) as success regardless of rg's exit
  # code, while a genuine no-match (0 lines, real exit 1) still reports correctly.
  describe "ripgrep early-close exit-status (#391)" do
    # Drives search_with_ripgrep with a stubbed pipe that delivers MORE than
    # max_results lines (so the impl deliberately closes early / sets more_exist)
    # and forces `$?` to exit status 1 (the broken-pipe code that aliases the
    # genuine no-match code on the affected platform).
    def grep_with_stubbed_pipe(lines_yielded, exit_status:)
      allow(tool).to receive(:ripgrep_available?).and_return(true)
      allow(IO).to receive(:popen) do |_argv, **_kw, &blk|
        fake = StringIO.new(lines_yielded.join)
        # The impl closes the pipe early; no-op the close so our shell run below
        # (not StringIO#close) is what sets $?.
        def fake.close = nil
        blk.call(fake)
        # Set `$?` to the requested exit status the way the broken-pipe close
        # would on the affected platform (rg killed mid-scan → exit 1).
        system("exit #{exit_status}")
      end
      tool.call("pattern" => "match", "path" => tmp_dir, "max_results" => 50)
    end

    it "returns the collected matches + 'more' on an early-close exit 1, NOT 'No matches'" do
      # 60 collected match lines > max_results(50) → the impl hits the cap,
      # sets more_exist, and closes early; rg then exits 1 (broken pipe).
      lines  = Array.new(60) { |i| "many.txt:#{i + 1}:match #{i}\n" }
      result = grep_with_stubbed_pipe(lines, exit_status: 1)
      out    = payload(result)

      expect(out).not_to include("No matches")
      # The 50 already-collected matches are returned, with the overflow flag.
      expect(out.lines.grep(/many\.txt:/).size).to eq(50)
      expect(out).to include("more")
      expect(result[:metrics]).to include("+")
    end

    it "still reports a GENUINE no-match (0 lines, real exit 1) correctly" do
      result = grep_with_stubbed_pipe([], exit_status: 1)
      expect(result).to be_a(String)
      expect(result).to include("No matches")
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
