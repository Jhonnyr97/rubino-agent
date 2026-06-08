# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::Files::ReadOperation do
  let(:root)      { Dir.mktmpdir("rubino_ws") }
  let(:workspace) { Rubino::Files::Workspace.new(root: root) }
  let(:operation) { described_class.new(workspace: workspace) }

  after { FileUtils.rm_rf(root) }

  it "returns file bytes with octet-stream content type" do
    File.write(File.join(root, "x.txt"), "hello")
    env = { "QUERY_STRING" => "path=x.txt", "rubino.json" => {} }
    status, headers, body = operation.call(Rubino::API::Request.new(env, {}))
    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("application/octet-stream")
    expect(body.first).to eq("hello")
  end

  it "raises ValidationError when path is missing" do
    env = { "QUERY_STRING" => "", "rubino.json" => {} }
    expect { operation.call(Rubino::API::Request.new(env, {})) }
      .to raise_error(Rubino::ValidationError)
  end

  it "raises NotFoundError when the file is missing" do
    env = { "QUERY_STRING" => "path=missing.txt", "rubino.json" => {} }
    expect { operation.call(Rubino::API::Request.new(env, {})) }
      .to raise_error(Rubino::NotFoundError)
  end

  describe "default workspace root (Bug A: artifact download)" do
    let(:tool_root) { Dir.mktmpdir("rubino_tool_ws") }

    before { allow(Rubino::Tools::Base).to receive(:workspace_root).and_return(tool_root) }
    after  { FileUtils.rm_rf(tool_root) }

    it "reads an artifact written under the tool workspace root" do
      File.write(File.join(tool_root, "artifact.txt"), "produced")
      env = { "QUERY_STRING" => "path=#{File.join(tool_root, "artifact.txt")}", "rubino.json" => {} }
      status, _headers, body = described_class.new.call(Rubino::API::Request.new(env, {}))
      expect(status).to eq(200)
      expect(body.first).to eq("produced")
    end

    it "still rejects traversal outside the tool workspace root" do
      env = { "QUERY_STRING" => "path=../../../../etc/passwd", "rubino.json" => {} }
      expect { described_class.new.call(Rubino::API::Request.new(env, {})) }
        .to raise_error(Rubino::Files::Workspace::PathTraversal)
    end
  end
end
