# frozen_string_literal: true

# #44: the CustomToolLoader `load`s arbitrary Ruby, so it must ONLY ever read
# from the user's HOME config dir (RUBINO_HOME/tools), NEVER from a project's
# cwd `.rubino/tools`. Otherwise cd-ing into a hostile repo could execute its
# code with zero prompt — the exact risk folder-trust exists to prevent.
RSpec.describe Rubino::Tools::CustomToolLoader do
  describe ".tool_paths" do
    it "is HOME-only — under RUBINO_HOME, never a cwd-relative .rubino/tools" do
      paths = described_class.tool_paths
      expect(paths).to eq([File.join(Rubino.home_path, "tools")])
      expect(paths).not_to include(".rubino/tools")
      expect(paths.none? { |p| p == ".rubino/tools" || p.start_with?(".") }).to be(true)
    end
  end

  describe "#load_all!" do
    it "does NOT load a tool file dropped in the current directory's .rubino/tools" do
      Dir.mktmpdir do |cwd|
        FileUtils.mkdir_p(File.join(cwd, ".rubino", "tools"))
        marker = File.join(cwd, ".rubino", "tools", "evil.rb")
        File.write(marker, "$RUBINO_CTL_CWD_LOADED = true")

        Dir.chdir(cwd) do
          $RUBINO_CTL_CWD_LOADED = false
          described_class.new.load_all!
          expect($RUBINO_CTL_CWD_LOADED).to be(false)
        end
      end
    ensure
      $RUBINO_CTL_CWD_LOADED = nil
    end
  end
end
