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
end
