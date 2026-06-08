# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Files boundary: workspace-scoped read + multipart upload.
RSpec.describe "API contract: files" do
  before { with_test_db }

  let(:workspace_root) { Dir.mktmpdir("ra-contract-files") }
  let(:workspace)      { Rubino::Files::Workspace.new(root: workspace_root) }

  after { FileUtils.rm_rf(workspace_root) }

  def contract_router
    read   = Rubino::API::Operations::Files::ReadOperation.new(workspace: workspace)
    upload = Rubino::API::Operations::Files::UploadOperation.new(workspace: workspace)
    router = Rubino::API::Router.new
    router.get  "/v1/files", to: ->(req) { read.call(req) }
    router.post "/v1/files", to: ->(req) { upload.call(req) }
    router
  end

  describe "GET /v1/files?path=" do
    it "200 + raw bytes with application/octet-stream" do
      File.write(File.join(workspace_root, "hello.txt"), "ciao")
      get_json "/v1/files?path=hello.txt"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["content-type"]).to eq("application/octet-stream")
      expect(last_response.body).to eq("ciao")
    end

    it "422 when ?path is missing" do
      get_json "/v1/files"
      expect(last_response.status).to eq(422)
      expect(json_body.dig("error", "code")).to eq("validation")
    end

    it "404 when the file does not exist" do
      get_json "/v1/files?path=ghost.txt"
      expect(last_response.status).to eq(404)
    end

    it "422 on path traversal (Workspace::PathTraversal -> ValidationError)" do
      get_json "/v1/files?path=../../etc/passwd"
      expect(last_response.status).to eq(422)
    end
  end

  describe "POST /v1/files (multipart)" do
    it "201 + descriptor when a 'file' part is present" do
      boundary = "AaB03x"
      body = +"--#{boundary}\r\n"
      body << "content-disposition: form-data; name=\"file\"; filename=\"upload.txt\"\r\n"
      body << "content-type: text/plain\r\n\r\n"
      body << "uploaded bytes\r\n"
      body << "--#{boundary}--\r\n"

      post "/v1/files", body,
           { "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}", "CONTENT_LENGTH" => body.bytesize.to_s }.merge(auth_headers)
      expect(last_response.status).to eq(201)
      expect(json_body).to include("id" => kind_of(String), "filename" => "upload.txt", "size" => "uploaded bytes".bytesize)
    end

    it "422 when content-type is not multipart" do
      post_json "/v1/files", { "ignored" => true }
      expect(last_response.status).to eq(422)
    end
  end
end
