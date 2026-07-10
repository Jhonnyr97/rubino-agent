# frozen_string_literal: true

RSpec.describe Rubino::MCP::MCPToolWrapper do
  subject(:wrapper) { described_class.new(mcp_tool, server_name: "filesystem") }

  let(:mcp_tool) { double("mcp_tool", name: "read_file", description: "Reads a file") }

  it "prefixes the tool name with the server name to avoid collisions" do
    expect(wrapper.name).to eq("filesystem_read_file")
  end

  # S1-MCP-2 — a hostile/buggy MCP server can advertise an absurdly long tool
  # name; uncapped it breaks the `tools` table and 400s the provider.
  it "caps an over-long advertised tool name" do
    huge = described_class.new(double("mcp_tool", name: "x" * 20_000, description: "d"),
                               server_name: "h")
    expect(huge.name.length).to eq(described_class::MAX_NAME_LENGTH)
    expect(huge.name).to start_with("h_xxx")
  end

  it "delegates the description to the wrapped MCP tool" do
    expect(wrapper.description).to eq("Reads a file")
  end

  it "defaults external MCP tools to :medium risk" do
    expect(wrapper.risk_level).to eq(:medium)
  end

  describe "class-level DSL security / presentation / redaction" do
    it "returns MCPSecurity via the Base instance accessor" do
      sec = wrapper.security
      expect(sec).to be_a(Rubino::MCP::MCPToolWrapper::MCPSecurity)
      expect(sec.risk).to eq(:medium)
      expect(sec.risky?).to be(true)
      expect(sec.sandbox).to eq(:none)
    end

    it "returns ToolPresentationCLI via the Base instance accessor" do
      expect(wrapper.presentation).to be_a(Rubino::Tools::ToolPresentationCLI)
    end

    it "explicitly declares redaction_profile as :shell (fail-safe for external MCP output)" do
      expect(described_class.redaction_profile).to eq(:shell)
    end
  end

  # #582 — the display layer marks MCP calls as external code. The contract is
  # driven off #mcp? (an object predicate), NOT the name shape, so a built-in
  # with an underscore name is never mistaken for `<server>_<tool>`.
  describe "MCP display contract (#582)" do
    it "reports it is an MCP tool" do
      expect(wrapper.mcp?).to be(true)
    end

    it "exposes the source server name" do
      expect(wrapper.mcp_server).to eq("filesystem")
    end

    it "exposes the bare (unprefixed) tool name the server advertised" do
      expect(wrapper.bare_name).to eq("read_file")
    end

    it "builds a `<bare> (mcp:<server>)` display label" do
      expect(wrapper.display_name).to eq("read_file (mcp:filesystem)")
    end

    it "leaves the model-facing #name as the prefixed name (display is separate)" do
      expect(wrapper.name).to eq("filesystem_read_file")
      expect(wrapper.display_name).not_to eq(wrapper.name)
    end
  end

  describe "#input_schema" do
    # #170 — the server-advertised JSON schema lives in params_schema; the
    # inherited RubyLLM::Tool#parameters DSL accessor is always empty for MCP
    # tools, so forwarding it presented every tool with `parameters: {}` and
    # the model had to guess argument names (server then rejects with -32602).
    it "forwards the server-declared params_schema and deep-symbolizes via the bridge" do
      schema = {
        "type" => "object",
        "properties" => { "path" => { "type" => "string" } },
        "required" => ["path"]
      }
      allow(mcp_tool).to receive(:params_schema).and_return(schema)

      expect(wrapper.input_schema).to eq(
        type: "object",
        properties: { path: { type: "string" } },
        required: ["path"]
      )
    end

    it "never uses the always-empty RubyLLM::Tool#parameters DSL accessor" do
      allow(mcp_tool).to receive_messages(params_schema: nil, parameters: {})

      expect(wrapper.input_schema).to eq(type: "object", properties: {})
      expect(mcp_tool).not_to have_received(:parameters)
    end

    it "falls back to an empty object schema otherwise" do
      expect(wrapper.input_schema).to eq(type: "object", properties: {})
    end

    # S1-MCP-1 — a server advertising a truthy non-Hash inputSchema (e.g. a
    # string) would otherwise be forwarded verbatim into the wire `parameters:`,
    # poisoning the whole tool list → provider 400s every subsequent call.
    it "coerces a non-Hash params_schema to an empty object schema" do
      allow(mcp_tool).to receive(:params_schema).and_return("this is not a schema")

      expect(wrapper.input_schema).to eq(type: "object", properties: {})
    end

    it "coerces a non-Hash params_schema in to_tool_definition too" do
      allow(mcp_tool).to receive(:params_schema).and_return("this is not a schema")

      expect(wrapper.to_tool_definition[:parameters]).to eq(type: "object", properties: {})
    end
  end

  describe "#params_schema" do
    it "delegates to the underlying mcp_tool" do
      schema = {
        "type" => "object",
        "properties" => { "path" => { "type" => "string" } },
        "required" => ["path"]
      }
      allow(mcp_tool).to receive(:params_schema).and_return(schema)

      expect(wrapper.params_schema).to eq(schema)
    end

    it "returns an empty object schema when mcp_tool has no params_schema" do
      allow(mcp_tool).to receive(:respond_to?).with(:params_schema).and_return(false)

      expect(wrapper.params_schema).to eq(type: "object", properties: {})
    end

    it "coerces a non-Hash params_schema to an empty object schema (S1-MCP-1)" do
      allow(mcp_tool).to receive(:params_schema).and_return("this is not a schema")

      expect(wrapper.params_schema).to eq(type: "object", properties: {})
    end
  end

  describe "#call" do
    it "executes the wrapped tool with symbolized keys and stringifies the result" do
      allow(mcp_tool).to receive(:execute).with(path: "a.txt").and_return(%w[line1 line2])

      expect(wrapper.call("path" => "a.txt")).to eq(%w[line1 line2].to_s)
      expect(mcp_tool).to have_received(:execute).with(path: "a.txt")
    end

    # #172 — ruby_llm-mcp reports tool failures by RETURNING { error: "…" }
    # instead of raising. Without the "Error:" prefix Tools::Result#errorish?
    # is false and the transcript renders the failure as "✓ done".
    it "maps an { error: … } result to the registry's Error: convention" do
      allow(mcp_tool).to receive(:execute).and_return({ error: "MCP error -32602: Input validation error" })

      output = wrapper.call("path" => "a.txt")

      expect(output).to eq("Error: MCP tool filesystem/read_file: MCP error -32602: Input validation error")
    end

    it "maps a string-keyed error result too" do
      allow(mcp_tool).to receive(:execute).and_return({ "error" => "boom" })

      expect(wrapper.call({})).to eq("Error: MCP tool filesystem/read_file: boom")
    end

    it "returns an Error: string (never raises) when the MCP tool fails" do
      allow(mcp_tool).to receive(:execute).and_raise(StandardError, "server gone")

      expect(wrapper.call({})).to eq("Error: MCP tool filesystem/read_file: server gone")
    end
  end

  describe "#to_tool_definition" do
    it "exposes the prefixed name and the forwarded server schema" do
      schema = {
        "type" => "object",
        "properties" => { "path" => { "type" => "string" } },
        "required" => ["path"]
      }
      allow(mcp_tool).to receive(:params_schema).and_return(schema)

      definition = wrapper.to_tool_definition

      expect(definition[:name]).to eq("filesystem_read_file")
      expect(definition[:description]).to eq("Reads a file")
      expect(definition[:parameters][:properties]).to have_key(:path)
      expect(definition[:parameters][:required]).to eq(["path"])
    end
  end
end
