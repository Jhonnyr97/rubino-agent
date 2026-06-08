# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe Rubino::API::Operations::Files::UploadOperation do
  let(:root)      { Dir.mktmpdir("rubino_ws") }
  let(:workspace) { Rubino::Files::Workspace.new(root: root) }
  let(:operation) { described_class.new(workspace: workspace) }

  after { FileUtils.rm_rf(root) }

  def multipart_env(filename:, content:)
    boundary = "----RubinoTestBoundary"
    body = +""
    body << "--#{boundary}\r\n"
    body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n"
    body << "Content-Type: application/octet-stream\r\n\r\n"
    body << content
    body << "\r\n--#{boundary}--\r\n"
    {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
      "CONTENT_LENGTH" => body.bytesize.to_s,
      "rack.input" => StringIO.new(body),
      "rubino.json" => {}
    }
  end

  it "stores the upload and returns id/filename/size" do
    env = multipart_env(filename: "report.txt", content: "hello world")
    status, body = operation.call(Rubino::API::Request.new(env, {}))
    expect(status).to eq(201)
    expect(body[:filename]).to eq("report.txt")
    expect(body[:size]).to eq(11)
    expect(body[:id]).to match(/\A[0-9a-f-]{36}\z/)
  end

  it "rejects non-multipart requests with 422" do
    env = { "CONTENT_TYPE" => "application/json", "rubino.json" => {} }
    expect { operation.call(Rubino::API::Request.new(env, {})) }
      .to raise_error(Rubino::ValidationError, /multipart/)
  end
end
