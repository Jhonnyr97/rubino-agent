# frozen_string_literal: true

# Dispatch + output for the workspace slash verbs /add-dir and /dirs.
RSpec.describe "Rubino::Commands::Executor workspace verbs" do
  let(:ui)     { Rubino::UI::Null.new }
  let(:loader) { Rubino::Commands::Loader.new(config: test_configuration) }
  subject(:exec) { Rubino::Commands::Executor.new(loader: loader, ui: ui) }

  let(:primary) { Dir.mktmpdir("ws-primary") }
  let(:extra)   { Dir.mktmpdir("ws-extra") }

  before { Rubino.configuration.set("terminal", "cwd", primary) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    Rubino::Workspace.reset!
    FileUtils.rm_f(Rubino::Trust.store_path)
    FileUtils.rm_rf(primary)
    FileUtils.rm_rf(extra)
  end

  def info_lines
    ui.messages.select { |m| %i[info status success error].include?(m[:level]) }
      .map { |m| m[:message].to_s }
  end

  describe "/add-dir" do
    it "adds the dir as a workspace root and reports it" do
      expect(exec.try_execute("/add-dir #{extra}")).to eq(:handled)
      expect(Rubino::Workspace.roots).to include(File.realpath(extra))
      expect(info_lines.join("\n")).to include("Added workspace root")
    end

    it "reports an error for a non-existent dir" do
      expect(exec.try_execute("/add-dir #{File.join(extra, 'nope')}")).to eq(:handled)
      expect(info_lines.join("\n")).to match(/no such directory/)
    end

    it "teaches usage when called bare" do
      expect(exec.try_execute("/add-dir")).to eq(:handled)
      expect(info_lines.join("\n")).to include("Usage: /add-dir")
    end
  end

  describe "/dirs" do
    it "lists the primary plus added roots" do
      Rubino::Workspace.add(extra)
      expect(exec.try_execute("/dirs")).to eq(:handled)
      joined = info_lines.join("\n")
      expect(joined).to include(File.realpath(primary))
      expect(joined).to include(File.realpath(extra))
    end

    it "marks an untrusted root" do
      expect(exec.try_execute("/dirs")).to eq(:handled)
      expect(info_lines.join("\n")).to include("untrusted")
    end
  end
end
