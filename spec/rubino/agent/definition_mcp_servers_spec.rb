# frozen_string_literal: true

# Per-agent MCP scoping from config.yml (#92): `agents.<name>.mcp_servers`
# applies to a Definition unless code passed an explicit value.
RSpec.describe Rubino::Agent::Definition do
  def stub_configuration(raw)
    config = Rubino::Config::Configuration.new(raw: raw, home_path: TEST_HOME)
    allow(Rubino).to receive(:configuration).and_return(config)
  end

  describe "#mcp_servers" do
    it "defaults to :all when neither code nor config scope the agent" do
      stub_configuration({})

      expect(described_class.new(name: "build").mcp_servers).to eq(:all)
    end

    it "reads the agent's server list from agents.<name>.mcp_servers" do
      stub_configuration("agents" => { "explore" => { "mcp_servers" => ["filesystem"] } })

      expect(described_class.new(name: "explore").mcp_servers).to eq(["filesystem"])
    end

    it "honors an explicit empty list (no MCP tools) from config" do
      stub_configuration("agents" => { "plan" => { "mcp_servers" => [] } })

      expect(described_class.new(name: "plan").mcp_servers).to eq([])
    end

    it "normalizes the YAML string \"all\" to :all (the value the Manager compares against)" do
      stub_configuration("agents" => { "build" => { "mcp_servers" => "all" } })

      expect(described_class.new(name: "build").mcp_servers).to eq(:all)
    end

    it "lets an explicit in-code value win over config" do
      stub_configuration("agents" => { "explore" => { "mcp_servers" => ["filesystem"] } })

      definition = described_class.new(name: "explore", mcp_servers: ["internal_api"])

      expect(definition.mcp_servers).to eq(["internal_api"])
    end

    it "does not scope other agents by an unrelated agents block" do
      stub_configuration("agents" => { "explore" => { "mcp_servers" => ["filesystem"] } })

      expect(described_class.new(name: "build").mcp_servers).to eq(:all)
    end
  end

  # #173 (regression of #92) — reading the config was not enough: the live
  # chat path is Lifecycle#load_tools → Definition#resolved_tools →
  # Registry.enabled_tools, which contained EVERY registered MCPToolWrapper.
  # Scoping must bite on resolved_tools itself, the set the model receives.
  describe "#resolved_tools MCP scoping (#173)" do
    def fake_mcp_tool(name)
      double("mcp_tool", name: name, description: "#{name} tool")
    end

    before do
      Rubino::Tools::Registry.reset!
      Rubino::Tools::Registry.register(Rubino::Tools::ReadTool.new)
      Rubino::Tools::Registry.register(
        Rubino::MCP::MCPToolWrapper.new(fake_mcp_tool("read_file"), server_name: "filesystem")
      )
      Rubino::Tools::Registry.register(
        Rubino::MCP::MCPToolWrapper.new(fake_mcp_tool("query"), server_name: "api")
      )
    end

    after { Rubino::Tools::Registry.reset! }

    it "exposes no MCP tools to an agent scoped to [] in config" do
      stub_configuration("agents" => { "build" => { "mcp_servers" => [] } })

      names = described_class.new(name: "build").resolved_tools.map(&:name)

      expect(names.grep(/^(filesystem|api)_/)).to be_empty
      expect(names).to include("read")
    end

    it "exposes only the allowed server's tools to a scoped agent" do
      stub_configuration("agents" => { "explore" => { "mcp_servers" => ["filesystem"] } })

      names = described_class.new(name: "explore").resolved_tools.map(&:name)

      expect(names).to include("filesystem_read_file")
      expect(names).not_to include("api_query")
    end

    it "exposes every server's tools to an unscoped agent" do
      stub_configuration({})

      names = described_class.new(name: "build").resolved_tools.map(&:name)

      expect(names).to include("filesystem_read_file", "api_query")
    end

    it "applies the scoping even when tools are an explicit name list" do
      stub_configuration("agents" => { "plan" => { "mcp_servers" => [] } })

      definition = described_class.new(name: "plan", tools: %w[read filesystem_read_file])

      expect(definition.resolved_tools.map(&:name)).to eq(["read"])
    end
  end
end
