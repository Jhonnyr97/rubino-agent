# frozen_string_literal: true

RSpec.describe Rubino::MCP::MCPToolWrapper do
  subject(:wrapper) { described_class.new(mcp_tool, server_name: "filesystem") }

  let(:mcp_tool) { double("mcp_tool", name: "read_file", description: "Reads a file") }

  it "prefixes the tool name with the server name to avoid collisions" do
    expect(wrapper.name).to eq("filesystem_read_file")
  end

  it "delegates the description to the wrapped MCP tool" do
    expect(wrapper.description).to eq("Reads a file")
  end

  it "defaults external MCP tools to :medium risk" do
    expect(wrapper.risk_level).to eq(:medium)
  end

  describe "#input_schema" do
    it "uses the MCP tool's parameters when exposed" do
      schema = { type: "object", properties: { path: { type: "string" } } }
      allow(mcp_tool).to receive(:parameters).and_return(schema)

      expect(wrapper.input_schema).to eq(schema)
    end

    it "falls back to an empty object schema otherwise" do
      expect(wrapper.input_schema).to eq(type: "object", properties: {})
    end
  end

  describe "#call" do
    it "executes the wrapped tool with symbolized keys and stringifies the result" do
      allow(mcp_tool).to receive(:execute).with(path: "a.txt").and_return(%w[line1 line2])

      expect(wrapper.call("path" => "a.txt")).to eq(%w[line1 line2].to_s)
      expect(mcp_tool).to have_received(:execute).with(path: "a.txt")
    end

    it "returns an error string (never raises) when the MCP tool fails" do
      allow(mcp_tool).to receive(:execute).and_raise(StandardError, "server gone")

      expect(wrapper.call({})).to eq("MCP tool error (filesystem/read_file): server gone")
    end
  end

  it "exposes the prefixed name in the LLM tool definition" do
    definition = wrapper.to_tool_definition

    expect(definition[:name]).to eq("filesystem_read_file")
    expect(definition[:description]).to eq("Reads a file")
  end
end
