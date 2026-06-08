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
  after { FileUtils.rm_rf(tmp_dir) }

  before do
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

  it "returns an error for non-existent directory" do
    result = tool.call("pattern" => "*.rb", "path" => "/no/such/dir")
    expect(result).to include("Error")
  end
end
