# frozen_string_literal: true

require "digest"

# Regression specs for r6 path-resolution stumbles (r6-dt2 F1, r6-dt5 F3).
#
# Both bugs only surface when the workspace primary root (terminal.cwd) differs
# from the process cwd — which is the normal case for `bin/dev`/the QA harness,
# and exactly the case here: terminal.cwd is pointed at a tmp dir while the spec
# process keeps running from the repo root. On the OLD code:
#   F1: `glob` of an ABSOLUTE path to a file that exists returned "No files
#       matched" because the pattern was File.join'd onto the base, doubling it.
#   F3: a workspace-relative `shopkit/cart.py` was File.expand_path'd against
#       Dir.pwd (repo root) instead of terminal.cwd, so it resolved one dir too
#       shallow and 404'd.
RSpec.describe "tool path resolution (r6 F1/F3)", :path_resolution do # rubocop:disable RSpec/DescribeClass
  let(:tmp_dir) { Dir.mktmpdir("path_resolution_spec") }
  # Nested package layout from the F3 report: <root>/shopkit/shopkit/cart.py.
  let(:nested_rel) { File.join("shopkit", "cart.py") }
  let(:nested_abs) { File.join(tmp_dir, "shopkit", "cart.py") }

  before do
    # Point the workspace root at tmp_dir. Dir.pwd stays the repo root, so the
    # two diverge — the only condition under which F1/F3 reproduce.
    # Sanity: the bugs only reproduce when the workspace root and Dir.pwd
    # diverge. Skip (rather than silently pass) in the unlikely case they match.
    skip "needs terminal.cwd != Dir.pwd to reproduce" if Dir.pwd == tmp_dir
    Rubino.configuration.set("terminal", "cwd", tmp_dir)
    FileUtils.mkdir_p(File.dirname(nested_abs))
    File.write(nested_abs, "PRICE = 10\n")
  end

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    FileUtils.rm_rf(tmp_dir)
  end

  describe "F1: glob with an absolute path to an existing file" do
    subject(:glob) { Rubino::Tools::GlobTool.new }

    def payload(result)
      result.is_a?(Hash) ? (result[:output] || result["output"]) : result
    end

    it "matches the real file (not 'No files matched')" do
      result = payload(glob.call("pattern" => nested_abs))
      expect(result).not_to include("No files matched")
      expect(result).to include("cart.py")
    end

    it "still matches a relative pattern anchored at the workspace root" do
      result = payload(glob.call("pattern" => "**/*.py"))
      expect(result).to include("cart.py")
    end

    it "still denies an absolute pattern outside the workspace (guard #299)" do
      result = glob.call("pattern" => "/etc/passwd")
      expect(result).to be_a(Hash)
      expect(result[:error_code]).to eq(:outside_workspace)
    end
  end

  describe "F3: read/edit of a workspace-relative nested path" do
    it "read resolves the relative path against the workspace root on the first try" do
      result = Rubino::Tools::ReadTool.new.call("file_path" => nested_rel)
      payload = result.is_a?(Hash) ? result[:output] : result
      expect(payload).not_to include("File not found")
      expect(payload).to include("PRICE = 10")
    end

    it "edit resolves the relative path against the workspace root on the first try" do
      tracker = Rubino::Tools::ReadTracker.new
      tracker.register(nested_abs, File.mtime(nested_abs), Digest::SHA256.hexdigest(File.binread(nested_abs)))

      edit = Rubino::Tools::EditTool.new
      edit.read_tracker = tracker
      result = edit.call("file_path" => nested_rel, "old_string" => "10", "new_string" => "20")

      expect(result).to be_a(Hash)
      expect(result[:output]).to include("Edit applied")
      expect(File.read(nested_abs)).to eq("PRICE = 20\n")
    end

    it "still refuses a relative path that escapes the workspace (guard #299)" do
      result = Rubino::Tools::EditTool.new.call(
        "file_path" => File.join("..", "..", "..", "etc", "passwd"),
        "old_string" => "x", "new_string" => "y"
      )
      expect(result).to include("outside")
    end
  end
end
