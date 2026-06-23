# frozen_string_literal: true

# #56b — /status must surface the workspace/cwd path. Only the launch banner and
# the /sessions picker used to show it, so a user juggling repos couldn't tell
# which window was which from /status alone. This pins the new `workspace` panel
# line carrying the primary workspace root (home collapsed to ~).
RSpec.describe Rubino::Commands::Handlers::Status do
  let(:ui) do
    Class.new do
      attr_reader :panels

      def initialize = @panels = {}
      def panel_line(label, value, **) = @panels[label.to_s] = value.to_s
      def separator = nil
      def respond_to_missing?(_name, _priv = false) = true
      def method_missing(_name, *_args) = nil
    end.new
  end

  let(:handler) { described_class.new(ui: ui, runner: nil) }

  it "shows the workspace path in /status" do
    allow(Rubino::Workspace).to receive(:primary_root).and_return("/work/projA")

    handler.show_status

    expect(ui.panels).to have_key("workspace")
    expect(ui.panels["workspace"]).to eq("/work/projA")
  end

  it "collapses the home directory to ~ like the launch banner" do
    allow(Rubino::Workspace).to receive(:primary_root).and_return(File.join(Dir.home, "code", "repo"))

    handler.show_status

    expect(ui.panels["workspace"]).to eq("~/code/repo")
  end
end
