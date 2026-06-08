# frozen_string_literal: true

RSpec.describe Rubino::Tools::AttachFileTool do
  subject(:tool) { described_class.new }

  let(:tmp_dir) { Dir.mktmpdir("attach_file_tool_spec") }

  before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    FileUtils.rm_rf(tmp_dir)
  end

  it "has name 'attach_file' and :low risk" do
    expect(tool.name).to eq("attach_file")
    expect(tool.risk_level).to eq(:low)
  end

  it "returns an artifact payload with absolute path, filename, size, and inferred content_type" do
    path = File.join(tmp_dir, "report.pdf")
    File.binwrite(path, "PDF-content-bytes")

    result = tool.call("file_path" => path)

    expect(result[:artifact]).to include(
      path:         path,
      filename:     "report.pdf",
      content_type: "application/pdf",
      byte_size:    "PDF-content-bytes".bytesize
    )
    expect(result[:output]).to include("report.pdf")
  end

  it "falls back to application/octet-stream for unknown extensions" do
    path = File.join(tmp_dir, "thing.unknownext")
    File.write(path, "x")
    result = tool.call("file_path" => path)
    expect(result[:artifact][:content_type]).to eq("application/octet-stream")
  end

  it "honours an explicit display filename override" do
    path = File.join(tmp_dir, "out.csv")
    File.write(path, "a,b,c\n")
    result = tool.call("file_path" => path, "filename" => "Q3 export.csv")
    expect(result[:artifact][:filename]).to eq("Q3 export.csv")
  end

  it "errors out when the file does not exist" do
    result = tool.call("file_path" => File.join(tmp_dir, "missing.txt"))
    expect(result[:output]).to include("File not found")
    expect(result[:artifact]).to be_nil
  end

  it "errors out when the path escapes the workspace" do
    outside = File.join(Dir.mktmpdir("attach_outside"), "leak.txt")
    File.write(outside, "leak")
    result = tool.call("file_path" => outside)
    expect(result[:output]).to include("escapes the workspace")
    expect(result[:artifact]).to be_nil
  ensure
    FileUtils.rm_rf(File.dirname(outside)) if outside
  end

  it "errors out when file_path is blank" do
    result = tool.call("file_path" => "")
    expect(result[:output]).to include("file_path is required")
  end
end
