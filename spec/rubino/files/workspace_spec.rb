# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe Rubino::Files::Workspace do
  let(:root)      { Dir.mktmpdir("rubino_ws") }
  let(:workspace) { described_class.new(root: root) }
  # @root is realpath'd in initialize (macOS /tmp → /private/tmp etc),
  # so anything we compare against on disk must be too.
  let(:root_real) { File.realpath(root) }

  after { FileUtils.rm_rf(root) }

  describe "#resolve" do
    it "returns the absolute path inside the root" do
      File.write(File.join(root, "hello.txt"), "hi")
      expect(workspace.resolve("hello.txt").to_s).to eq(File.join(root_real, "hello.txt"))
    end

    it "raises on traversal attempts" do
      expect { workspace.resolve("../etc/passwd") }.to raise_error(described_class::PathTraversal)
    end

    it "raises on absolute-path traversal" do
      expect { workspace.resolve("/etc/passwd") }.to raise_error(described_class::PathTraversal)
    end

    it "accepts an absolute path that resolves into the workspace via a symlink" do
      # Regression: macOS' /tmp is a symlink to /private/tmp, so a tool
      # that ran File.expand_path on a sandboxed file produced
      # /private/tmp/...; Workspace#resolve compared it to its raw root
      # /tmp/... and raised PathTraversal, breaking attach_file downloads.
      File.write(File.join(root, "report.md"), "x")
      # Build a symlink directory pointing at root, then resolve a path
      # through the symlink. Workspace should normalise both sides.
      Dir.mktmpdir do |outer|
        link = File.join(outer, "link")
        File.symlink(root, link)
        resolved = workspace.resolve(File.join(link, "report.md"))
        expect(resolved.to_s).to eq(File.join(root_real, "report.md"))
      end
    end
  end

  describe "#read" do
    it "returns the file content as bytes" do
      File.write(File.join(root, "data.bin"), "binary")
      expect(workspace.read("data.bin")).to eq("binary")
    end

    it "raises NotFoundError when the file is missing" do
      expect { workspace.read("missing.txt") }.to raise_error(Rubino::NotFoundError)
    end
  end

  describe "#upload" do
    it "writes the IO under uploads/ and returns the descriptor" do
      io = StringIO.new("payload")
      descriptor = workspace.upload(filename: "doc.txt", io: io)
      expect(descriptor[:filename]).to eq("doc.txt")
      expect(descriptor[:size]).to eq(7)
      expect(File.read(descriptor[:path])).to eq("payload")
      expect(descriptor[:path]).to start_with(File.join(root_real, "uploads", "#{descriptor[:id]}-doc.txt"))
    end

    it "strips directory components from the filename" do
      io = StringIO.new("x")
      descriptor = workspace.upload(filename: "../../evil.txt", io: io)
      expect(descriptor[:filename]).to eq("evil.txt")
    end
  end
end
