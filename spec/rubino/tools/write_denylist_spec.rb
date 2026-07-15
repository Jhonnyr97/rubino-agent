# frozen_string_literal: true

# #446: the always-on write-side credential DENYLIST (#413) was replaced by a
# unified APPROVAL GATE in Security::ApprovalPolicy#decide. The per-tool
# self-refusal is GONE — a write/edit that reaches the
# tool's #call has already been approved, so it actually writes the secret.
# These examples pin the new TOOL-LEVEL behavior (an approved secret write
# proceeds, a normal file is unaffected). The gate itself — when :ask fires,
# approve/deny/headless — is covered end-to-end in
# spec/rubino/security/secret_file_gate_spec.rb.
# rubocop:disable RSpec/DescribeClass -- spans the write tools by design
RSpec.describe "secret writes proceed at the tool level (gate moved upstream, #446)" do
  def payload(result) = result.is_a?(Hash) ? result[:output] : result

  let(:tmp_dir) { Dir.mktmpdir("write_secret_gate_spec") }

  before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    FileUtils.rm_rf(tmp_dir)
  end

  describe Rubino::Tools::WriteTool do
    subject(:tool) { described_class.new }

    it "writes an APPROVED .env inside the workspace (no per-tool refusal)" do
      path = File.join(tmp_dir, ".env")
      out  = payload(tool.call("file_path" => path, "content" => "API_KEY=set"))
      expect(File.read(path)).to eq("API_KEY=set")
      expect(out).to include("created")
    end

    it "still writes a normal file in the same workspace" do
      path = File.join(tmp_dir, "app.rb")
      out  = payload(tool.call("file_path" => path, "content" => "puts :ok"))
      expect(File.read(path)).to eq("puts :ok")
      expect(out).to include("created")
    end
  end

  describe Rubino::Tools::EditTool do
    subject(:tool) { described_class.new.tap { |t| t.read_tracker = Rubino::Tools::ReadTracker.new } }

    it "edits an APPROVED .env (no per-tool refusal, read-gate still applies)" do
      path = File.join(tmp_dir, ".env")
      File.write(path, "API_KEY=old\n")
      tool.read_tracker.register(path, File.mtime(path), nil)
      result = tool.call("file_path" => path, "old_string" => "old", "new_string" => "new")
      expect(payload(result)).to include("Edit applied")
      expect(File.read(path)).to eq("API_KEY=new\n")
    end
  end

  describe "#{Rubino::Tools::EditTool} (edits array form)" do
    subject(:tool) { Rubino::Tools::EditTool.new.tap { |t| t.read_tracker = Rubino::Tools::ReadTracker.new } }

    it "applies an APPROVED multi-edit .env in the workspace" do
      path = File.join(tmp_dir, ".env")
      File.write(path, "A=1\nB=2\n")
      tool.read_tracker.register(path, File.mtime(path), nil)
      result = tool.call("file_path" => path,
                         "edits" => [{ "old_string" => "A=1", "new_string" => "A=9" }])
      expect(payload(result)).to include("Applied")
      expect(File.read(path)).to eq("A=9\nB=2\n")
    end
  end
end
# rubocop:enable RSpec/DescribeClass
