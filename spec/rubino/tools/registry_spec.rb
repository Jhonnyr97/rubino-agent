# frozen_string_literal: true

RSpec.describe Rubino::Tools::Registry do
  before { described_class.reset! }

  # Force Zeitwerk to load all tool classes before tests run
  before(:all) do
    Rubino.loader.eager_load
  end

  describe ".register and .find" do
    it "registers and finds a tool" do
      tool = Rubino::Tools::GitTool.new
      described_class.register(tool)
      expect(described_class.find("git")).to eq(tool)
    end

    it "returns nil for unregistered tool" do
      expect(described_class.find("unknown")).to be_nil
    end
  end

  describe ".unregister" do
    it "removes a tool by name (#182 — MCP off drops the server's wrappers)" do
      described_class.register(Rubino::Tools::GitTool.new)
      described_class.unregister("git")
      expect(described_class.find("git")).to be_nil
    end
  end

  describe ".all" do
    it "returns all registered tools" do
      described_class.register(Rubino::Tools::GitTool.new)
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
      expect(described_class.find("git")).to         be_a(Rubino::Tools::GitTool)
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
