# frozen_string_literal: true

require "fileutils"

RSpec.describe Rubino::Util::IgnoreRules do
  subject(:rules) { described_class.new }

  describe "#ignored? in a git repo (#375b/#375c)" do
    let(:repo) { Dir.mktmpdir("ignore_rules") }

    before do
      skip "git not installed" unless system("which git > /dev/null 2>&1")
      Dir.chdir(repo) do
        system("git", "init", "-q", out: File::NULL, err: File::NULL)
        system("git", "config", "user.email", "t@t", out: File::NULL, err: File::NULL)
        system("git", "config", "user.name", "t", out: File::NULL, err: File::NULL)
      end
      File.write(File.join(repo, ".gitignore"), "secret.txt\nbuild/\n")
      File.write(File.join(repo, "kept.txt"), "")
      File.write(File.join(repo, "secret.txt"), "")
      FileUtils.mkdir_p(File.join(repo, "build"))
      File.write(File.join(repo, "build", "out.o"), "")
    end

    after { FileUtils.rm_rf(repo) }

    it "treats git-ignored files as ignored and tracked/untracked files as kept" do
      expect(rules.ignored?(File.join(repo, "kept.txt"), repo)).to be(false)
      expect(rules.ignored?(File.join(repo, "secret.txt"), repo)).to be(true)
      expect(rules.ignored?(File.join(repo, "build", "out.o"), repo)).to be(true)
    end
  end

  describe "#ignored? outside a git repo (fallback denylist)" do
    let(:dir) { Dir.mktmpdir("ignore_rules_nogit") }

    before do
      File.write(File.join(dir, "app.rb"), "")
      FileUtils.mkdir_p(File.join(dir, "node_modules"))
      File.write(File.join(dir, "node_modules", "lib.js"), "")
    end

    after { FileUtils.rm_rf(dir) }

    it "ignores built-in noise dirs deterministically without git" do
      expect(rules.ignored?(File.join(dir, "app.rb"), dir)).to be(false)
      expect(rules.ignored?(File.join(dir, "node_modules", "lib.js"), dir)).to be(true)
    end
  end
end
