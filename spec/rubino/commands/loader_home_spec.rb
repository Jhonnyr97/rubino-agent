# frozen_string_literal: true

require "tmpdir"

# Issue #38: the custom-commands loader must derive its user-home commands
# directory from the resolved home (RUBINO_HOME -> else ~/.rubino), not a
# literal ~/.rubino, so commands dropped in a custom home are discovered.
RSpec.describe "Rubino::Commands::Loader RUBINO_HOME resolution" do
  let(:custom_home) { Dir.mktmpdir("rubino-home") }

  around do |example|
    prev = ENV.fetch("RUBINO_HOME", nil)
    ENV["RUBINO_HOME"] = custom_home
    Rubino.reload_configuration!
    example.run
  ensure
    ENV["RUBINO_HOME"] = prev
    Rubino.reload_configuration!
    FileUtils.rm_rf(custom_home)
  end

  it "points the default user-home commands dir at the resolved RUBINO_HOME" do
    expect(Rubino::Commands::Loader.default_command_paths)
      .to include(File.join(custom_home, "commands"))
    expect(Rubino::Commands::Loader.default_command_paths)
      .not_to include("~/.rubino/commands")
  end

  it "discovers a command file dropped into <RUBINO_HOME>/commands" do
    cmds = File.join(custom_home, "commands")
    FileUtils.mkdir_p(cmds)
    File.write(File.join(cmds, "review.md"), "Review the diff. $ARGUMENTS\n")

    loader = Rubino::Commands::Loader.new
    expect(loader.names).to include("/review")
    expect(loader.find("review")).not_to be_nil
  end
end
