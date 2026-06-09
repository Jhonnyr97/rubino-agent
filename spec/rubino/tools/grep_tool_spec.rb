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

  after { FileUtils.rm_rf(tmp_dir) }

  before do
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

  it "returns an error for non-existent path" do
    result = tool.call("pattern" => "x", "path" => "/no/such/dir")
    expect(result).to include("Error")
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
end
