# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "tmpdir"
require "fileutils"
require "stringio"
require "json"

RSpec.describe "Rubino::API::Operations::Files::UploadOperation size cap" do
  let(:root)      { Dir.mktmpdir("rubino_ws") }
  let(:workspace) { Rubino::Files::Workspace.new(root: root) }
  let(:operation) { Rubino::API::Operations::Files::UploadOperation.new(workspace: workspace) }
  let(:limit)     { 1024 }

  before do
    Rubino.configuration.set("api", "max_upload_bytes", limit)
  end

  after do
    FileUtils.rm_rf(root)
    Rubino.configuration.set("api", "max_upload_bytes", 50 * 1024 * 1024)
  end

  def multipart_body(filename:, content:, boundary: "----RubinoSizeBoundary")
    body = +""
    body << "--#{boundary}\r\n"
    body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n"
    body << "Content-Type: application/octet-stream\r\n\r\n"
    body << content
    body << "\r\n--#{boundary}--\r\n"
    body
  end

  def multipart_env(body, boundary: "----RubinoSizeBoundary", content_length: body.bytesize.to_s)
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
      "rack.input" => StringIO.new(body),
      "rubino.json" => {}
    }
    env["CONTENT_LENGTH"] = content_length unless content_length.nil?
    env
  end

  it "accepts uploads below the cap" do
    body = multipart_body(filename: "small.bin", content: "x" * 64)
    env  = multipart_env(body)
    status, payload = operation.call(Rubino::API::Request.new(env, {}))

    expect(status).to eq(201)
    expect(payload[:size]).to eq(64)
  end

  it "rejects uploads whose declared Content-Length exceeds the cap before any IO" do
    body = multipart_body(filename: "fake.bin", content: "x" * 32)
    env  = multipart_env(body, content_length: (limit + 1).to_s)

    # Stream must NOT be drained when Content-Length already overflows the cap.
    input_before = env["rack.input"]
    expect(input_before).to receive(:read).never
    expect(input_before).to receive(:gets).never

    expect { operation.call(Rubino::API::Request.new(env, {})) }
      .to raise_error(Rubino::PayloadTooLargeError) do |err|
        expect(err.details[:limit_bytes]).to eq(limit)
      end
  end

  it "produces a canonical 413 envelope when routed through ErrorHandler" do
    body = multipart_body(filename: "big.bin", content: "x" * 32)
    env  = multipart_env(body, content_length: (limit + 1).to_s)
    upload_op = operation
    inner = ->(_req) { upload_op.call(Rubino::API::Request.new(env, {})) }
    handler_app = lambda do |_e|
      result = inner.call(nil)
      [result[0], { "content-type" => "application/json" }, [JSON.generate(result[1])]]
    end
    logger  = Rubino::Logger.new(io: StringIO.new, level: :error)
    handler = Rubino::API::Middleware::ErrorHandler.new(handler_app, logger: logger)

    status, headers, body_chunks = handler.call(env)
    payload = JSON.parse(body_chunks.first)

    expect(status).to eq(413)
    expect(headers["content-type"]).to eq("application/json")
    expect(payload).to match(
      "error" => hash_including(
        "code" => "payload_too_large",
        "message" => /multipart upload exceeds/,
        "details" => hash_including("limit_bytes" => limit)
      )
    )
  end

  it "aborts mid-stream when Content-Length is absent and the body exceeds the cap, leaving no tempfile on disk" do
    oversize = "x" * (limit + 512)
    body     = multipart_body(filename: "stream.bin", content: oversize)
    # No Content-Length (e.g. chunked transfer) so the up-front check is a
    # no-op; the cap must trip from the wrapped rack.input mid-parse.
    env      = multipart_env(body, content_length: nil)

    uploads_before = Dir.glob(File.join(root, "uploads", "*"))
    tmp_before     = Dir.glob(File.join(Dir.tmpdir, "RackMultipart*"))

    expect { operation.call(Rubino::API::Request.new(env, {})) }
      .to raise_error(Rubino::PayloadTooLargeError)

    uploads_after = Dir.glob(File.join(root, "uploads", "*"))
    tmp_after     = Dir.glob(File.join(Dir.tmpdir, "RackMultipart*"))

    expect(uploads_after).to eq(uploads_before)
    expect(tmp_after - tmp_before).to be_empty
  end
end
