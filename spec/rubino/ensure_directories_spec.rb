# frozen_string_literal: true

require "tmpdir"

# #65: the home holds secrets (.env) and the database. ensure_directories! is
# the single shared path every entry point (setup/chat/prompt/doctor) uses to
# materialize the home, so it must create it owner-only (0700) exactly like
# `rubino setup` — not at the umask's 0755 when auto-created by chat/prompt.
RSpec.describe Rubino, ".ensure_directories!" do
  around do |example|
    Dir.mktmpdir("rubino_home_perms") do |dir|
      orig = ENV.fetch("RUBINO_HOME", nil)
      ENV["RUBINO_HOME"] = File.join(dir, "home")
      example.run
    ensure
      orig.nil? ? ENV.delete("RUBINO_HOME") : ENV["RUBINO_HOME"] = orig
    end
  end

  it "creates an auto-created home owner-only (0700), matching setup" do
    home = ENV.fetch("RUBINO_HOME")

    described_class.ensure_directories!

    expect(File.stat(home).mode & 0o777).to eq(0o700)
  end

  it "creates the expected subdirectories" do
    home = ENV.fetch("RUBINO_HOME")

    described_class.ensure_directories!

    %w[memories sessions logs skills commands tools plugins].each do |sub|
      expect(File.directory?(File.join(home, sub))).to be(true)
    end
  end

  it "re-tightens an existing world-readable home to 0700" do
    home = ENV.fetch("RUBINO_HOME")
    FileUtils.mkdir_p(home)
    File.chmod(0o755, home)

    described_class.ensure_directories!

    expect(File.stat(home).mode & 0o777).to eq(0o700)
  end
end
