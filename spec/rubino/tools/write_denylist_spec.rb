# frozen_string_literal: true

# Always-on write-side credential denylist (#413, mirrors Hermes
# file_safety.is_write_denied). The denylist is INDEPENDENT of the workspace
# sandbox: write/edit/multi_edit/apply_patch must refuse credential & system
# paths even when tools.workspace_strict=false AND even when the target sits
# inside the workspace. A normal file in the same workspace stays writable.
RSpec.describe "write-side credential denylist (#413)" do
  def payload(result) = result.is_a?(Hash) ? result[:output] : result

  let(:tmp_dir) { Dir.mktmpdir("write_denylist_spec") }

  # workspace_strict OFF for the whole suite — proves the denylist is a floor
  # that does NOT depend on the sandbox toggle. terminal.cwd is still pointed at
  # tmp_dir so the .env / .ssh fixtures land INSIDE the workspace.
  before do
    Rubino.configuration.set("terminal", "cwd", tmp_dir)
    Rubino.configuration.set("tools", "workspace_strict", false)
  end

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    Rubino.configuration.set("tools", "workspace_strict", nil)
    FileUtils.rm_rf(tmp_dir)
  end

  describe Rubino::Tools::WriteTool do
    subject(:tool) { described_class.new }

    it "refuses to write a .env file inside the workspace (strict off)" do
      path = File.join(tmp_dir, ".env")
      result = tool.call("file_path" => path, "content" => "API_KEY=leak")
      expect(result).to be_a(Hash)
      expect(result[:error_code]).to eq(:write_secret_denied)
      expect(File.exist?(path)).to be false
    end

    it "refuses to write .env.production / .envrc / .git-credentials too" do
      %w[.env.production .envrc .git-credentials .netrc .npmrc].each do |name|
        path = File.join(tmp_dir, name)
        result = tool.call("file_path" => path, "content" => "x")
        expect(result).to be_a(Hash), "#{name} should be denied"
        expect(result[:error_code]).to eq(:write_secret_denied)
        expect(File.exist?(path)).to be false
      end
    end

    it "refuses to write into ~/.ssh (e.g. id_rsa / authorized_keys)" do
      %w[id_rsa authorized_keys config].each do |name|
        path = File.join(Dir.home, ".ssh", name)
        result = tool.call("file_path" => path, "content" => "x")
        expect(result).to be_a(Hash), "~/.ssh/#{name} should be denied"
        expect(result[:error_code]).to eq(:write_secret_denied)
      end
    end

    it "refuses to write /etc/sudoers and /etc/passwd" do
      ["/etc/sudoers", "/etc/passwd"].each do |path|
        result = tool.call("file_path" => path, "content" => "x")
        expect(result).to be_a(Hash), "#{path} should be denied"
        expect(result[:error_code]).to eq(:write_secret_denied)
      end
    end

    it "still writes a normal file in the same workspace" do
      path = File.join(tmp_dir, "app.rb")
      out  = payload(tool.call("file_path" => path, "content" => "puts :ok"))
      expect(File.read(path)).to eq("puts :ok")
      expect(out).to include("created")
    end
  end

  describe Rubino::Tools::EditTool do
    # A read tracker so the read-gate doesn't pre-empt the denylist — the
    # denylist must fire FIRST regardless. The fixture file is created on disk
    # so "File not found" can't pre-empt it either.
    subject(:tool) { described_class.new.tap { |t| t.read_tracker = Rubino::Tools::ReadTracker.new } }

    it "refuses to edit a .env file (denylist before read-gate)" do
      path = File.join(tmp_dir, ".env")
      File.write(path, "API_KEY=old\n")
      result = tool.call("file_path" => path, "old_string" => "old", "new_string" => "new")
      expect(result).to be_a(Hash)
      expect(result[:error_code]).to eq(:write_secret_denied)
      expect(File.read(path)).to eq("API_KEY=old\n")
    end

    it "refuses to edit /etc/sudoers" do
      result = tool.call("file_path" => "/etc/sudoers", "old_string" => "a", "new_string" => "b")
      expect(result).to be_a(Hash)
      expect(result[:error_code]).to eq(:write_secret_denied)
    end
  end

  describe Rubino::Tools::MultiEditTool do
    subject(:tool) { described_class.new.tap { |t| t.read_tracker = Rubino::Tools::ReadTracker.new } }

    it "refuses to multi_edit a .ssh/id_rsa path" do
      path = File.join(Dir.home, ".ssh", "id_rsa")
      result = tool.call("file_path" => path,
                         "edits" => [{ "old_string" => "a", "new_string" => "b" }])
      expect(result).to be_a(Hash)
      expect(result[:error_code]).to eq(:write_secret_denied)
    end
  end

  describe Rubino::Tools::PatchTool do
    subject(:tool) { described_class.new }

    it "refuses an apply_patch that creates a .env file" do
      patch = <<~PATCH
        --- /dev/null
        +++ b/.env
        @@ -0,0 +1,1 @@
        +API_KEY=leak
      PATCH
      result = tool.call("patch" => patch, "base_path" => tmp_dir)
      expect(result).to include("refusing to WRITE")
      expect(File.exist?(File.join(tmp_dir, ".env"))).to be false
    end
  end
end
