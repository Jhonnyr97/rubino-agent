# frozen_string_literal: true

RSpec.describe Rubino::Tools::Registry do
  # Force Zeitwerk to load all tool classes before tests run
  before(:all) do
    Rubino.loader.eager_load
  end

  describe ".register and .find" do
    it "registers and finds a tool" do
      tool = Rubino::Tools::GlobTool.new
      described_class.register(tool)
      expect(described_class.find("glob")).to eq(tool)
    end

    it "returns nil for unregistered tool" do
      expect(described_class.find("unknown")).to be_nil
    end
  end

  describe ".unregister" do
    it "removes a tool by name (#182 — MCP off drops the server's wrappers)" do
      described_class.register(Rubino::Tools::GlobTool.new)
      described_class.unregister("glob")
      expect(described_class.find("glob")).to be_nil
    end
  end

  describe ".all" do
    it "returns all registered tools" do
      described_class.register(Rubino::Tools::GlobTool.new)
      described_class.register(Rubino::Tools::ReadTool.new)
      expect(described_class.all.size).to eq(2)
    end
  end

  describe ".register_defaults!" do
    it "registers the default tools" do
      described_class.register_defaults!
      expect(described_class.find("read")).to        be_a(Rubino::Tools::ReadTool)
      expect(described_class.find("write")).to       be_a(Rubino::Tools::WriteTool)
      expect(described_class.find("edit")).to        be_a(Rubino::Tools::EditTool)
      expect(described_class.find("multi_edit")).to  be_a(Rubino::Tools::MultiEditTool)
      expect(described_class.find("shell")).to       be_a(Rubino::Tools::ShellTool)
      expect(described_class.find("shell_output")).to be_a(Rubino::Tools::ShellOutputTool)
      expect(described_class.find("shell_input")).to be_a(Rubino::Tools::ShellInputTool)
      expect(described_class.find("shell_kill")).to  be_a(Rubino::Tools::ShellKillTool)
      expect(described_class.find("ruby")).to        be_a(Rubino::Tools::RubyTool)
      expect(described_class.find("websearch")).to   be_a(Rubino::Tools::WebSearchTool)
      expect(described_class.find("todowrite")).to   be_a(Rubino::Tools::TodoTool)
      expect(described_class.find("skill")).to       be_a(Rubino::Skills::SkillTool)
      expect(described_class.find("task")).to        be_a(Rubino::Tools::TaskTool)
      expect(described_class.find("task_result")).to be_a(Rubino::Tools::TaskResultTool)
      expect(described_class.find("task_stop")).to   be_a(Rubino::Tools::TaskStopTool)
    end

    # #536/#553: the dedicated `git` tool was removed. It was risk_level :low
    # (auto-allowed) and ran git with arbitrary args, bypassing the shell's
    # git_exec_vector? hardening — an RCE. Git now runs through the `shell`
    # tool, which gates the exec vectors. The model must NOT see a `git` tool.
    it "does NOT register a dedicated `git` tool (#536/#553 — RCE removed)" do
      described_class.register_defaults!
      expect(described_class.find("git")).to be_nil
      expect(described_class.all.map(&:name)).not_to include("git")
    end
  end

  # #582 — the single display-label resolution point both the live tool card
  # and the approval card route through. An MCP tool reads its source marker; a
  # built-in is unchanged. Detection is by the registered object's #mcp?, NOT
  # the name shape, so an underscore-named built-in is never mis-tagged.
  describe ".display_label" do
    it "returns the bare name for a built-in tool" do
      described_class.register(Rubino::Tools::GlobTool.new)
      expect(described_class.display_label("glob")).to eq("glob")
    end

    it "does NOT mark an underscore-named built-in as MCP" do
      described_class.register(Rubino::Tools::ReadAttachmentTool.new)
      described_class.register(Rubino::Tools::ShellOutputTool.new)
      expect(described_class.display_label("read_attachment")).to eq("read_attachment")
      expect(described_class.display_label("shell_output")).to eq("shell_output")
    end

    it "marks an MCP tool with its `<bare> (mcp:<server>)` source" do
      mcp_tool = double("mcp_tool", name: "echo", description: "echoes")
      described_class.register(Rubino::MCP::MCPToolWrapper.new(mcp_tool, server_name: "chaos"))
      expect(described_class.display_label("chaos_echo")).to eq("echo (mcp:chaos)")
    end

    it "falls back to the bare name for an unregistered tool" do
      expect(described_class.display_label("nope")).to eq("nope")
    end
  end

  describe ".tool_definitions" do
    it "returns definition hashes for enabled tools" do
      described_class.register_defaults!
      definitions = described_class.tool_definitions
      expect(definitions).to be_an(Array)
      expect(definitions).not_to be_empty
      expect(definitions.first).to have_key(:name)
      expect(definitions.first).to have_key(:description)
      expect(definitions.first).to have_key(:parameters)
    end
  end
end
