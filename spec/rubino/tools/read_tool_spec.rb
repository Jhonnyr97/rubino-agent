# frozen_string_literal: true

RSpec.describe Rubino::Tools::ReadTool do
  subject(:tool) { described_class.new }

  # Successful tool calls now return {output:, metrics:}; error paths still
  # return a plain String. This helper extracts the rendered text so existing
  # `out` matchers continue to apply unchanged.
  def payload(result) = result.is_a?(Hash) ? result[:output] : result

  let(:tmp_dir) { Dir.mktmpdir("read_tool_spec") }

  after { FileUtils.rm_rf(tmp_dir) }

  it "has name 'read' and :low risk" do
    expect(tool.name).to eq("read")
    expect(tool.risk_level).to eq(:low)
  end

  it "returns line-numbered content for a small file" do
    path = File.join(tmp_dir, "a.txt")
    File.write(path, "alpha\nbeta\ngamma\n")
    out = payload(tool.call("file_path" => path))
    expect(out).to match(/^\s*1\talpha$/)
    expect(out).to match(/^\s*2\tbeta$/)
    expect(out).to match(/^\s*3\tgamma$/)
  end

  it "reports `N lines` metric for the done header" do
    path = File.join(tmp_dir, "a.txt")
    File.write(path, "alpha\nbeta\ngamma\n")
    expect(tool.call("file_path" => path)[:metrics]).to eq("3 lines")
  end

  it "honours offset and limit" do
    path = File.join(tmp_dir, "many.txt")
    File.write(path, (1..50).map { |i| "line#{i}" }.join("\n"))

    out = payload(tool.call("file_path" => path, "offset" => 10, "limit" => 3))
    expect(out).to include("line10")
    expect(out).to include("line11")
    expect(out).to include("line12")
    expect(out).not_to include("line13")
    expect(out).to include("[showing lines 10-12 of 50")
  end

  it "tells the LLM how to page when there is more content" do
    path = File.join(tmp_dir, "big.txt")
    File.write(path, (1..5000).map { |i| "x#{i}" }.join("\n"))
    out = payload(tool.call("file_path" => path))
    expect(out).to include("offset=2001")
  end

  it "truncates absurdly long lines" do
    path = File.join(tmp_dir, "long.txt")
    File.write(path, "a" * 5000)
    out = payload(tool.call("file_path" => path))
    expect(out).to include("[line truncated]")
  end

  it "returns an error for missing file" do
    expect(tool.call("file_path" => "/no/such/file.txt")).to include("File not found")
  end

  it "returns an error when offset is past EOF" do
    path = File.join(tmp_dir, "small.txt")
    File.write(path, "one\ntwo\n")
    out = tool.call("file_path" => path, "offset" => 999)
    expect(out).to include("past end of file")
  end

  it "refuses directories" do
    out = tool.call("file_path" => tmp_dir)
    expect(out).to include("Not a regular file")
  end

  it "caps the window at ~100KB of very long lines and tells the model to narrow" do
    path = File.join(tmp_dir, "wide.txt")
    # 100 lines × 2000 chars ≈ 200KB rendered → over the 100KB byte cap.
    File.write(path, Array.new(100) { "x" * 2000 }.join("\n"))
    out = payload(tool.call("file_path" => path, "limit" => 100))
    expect(out).to include("window capped at ~100KB")
    expect(out).to match(/continue with offset=\d+/)
    expect(out.bytesize).to be <= 110_000 # cap + footer slack, not the full 200KB
  end

  describe "duplicate-read nudge" do
    let(:tracker) { Rubino::Tools::ReadTracker.new }

    before { tool.read_tracker = tracker }

    it "returns a [DUPLICATE READ] nudge on an exact repeat instead of re-emitting content" do
      path = File.join(tmp_dir, "a.txt")
      File.write(path, "alpha\nbeta\ngamma\n")

      first = payload(tool.call("file_path" => path, "offset" => 1, "limit" => 3))
      expect(first).to include("alpha")

      second = payload(tool.call("file_path" => path, "offset" => 1, "limit" => 3))
      expect(second).to include("[DUPLICATE READ]")
      expect(second).not_to include("alpha")
    end

    it "does NOT flag a different window of the same file as a duplicate" do
      path = File.join(tmp_dir, "many.txt")
      File.write(path, (1..50).map { |i| "line#{i}" }.join("\n"))

      payload(tool.call("file_path" => path, "offset" => 1, "limit" => 5))
      other = payload(tool.call("file_path" => path, "offset" => 10, "limit" => 5))
      expect(other).not_to include("[DUPLICATE READ]")
      expect(other).to include("line10")
    end
  end
end
