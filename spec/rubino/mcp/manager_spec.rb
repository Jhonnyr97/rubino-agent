# frozen_string_literal: true

RSpec.describe Rubino::MCP::Manager do
  subject(:manager) { described_class.new(config: config) }

  let(:ui) { Rubino::UI::Null.new }
  let(:raw) do
    {
      "mcp" => {
        "servers" => {
          "filesystem" => { "transport" => "stdio", "command" => "fake-mcp-server", "args" => ["."] },
          "api" => { "transport" => "sse", "url" => "https://mcp.example.test/sse" }
        }
      }
    }
  end
  let(:config) { Rubino::Config::Configuration.new(raw: raw, home_path: TEST_HOME) }

  before { Rubino.ui = ui }

  # No network, no subprocesses: RubyLLM::MCP.client is stubbed with plain
  # doubles that quack like ruby_llm-mcp clients (tools / alive? / stop).
  def fake_tool(name)
    double("mcp_tool", name: name, description: "#{name} tool")
  end

  def fake_client(tool_names, alive: true)
    double("mcp_client", tools: tool_names.map { |n| fake_tool(n) }, alive?: alive, stop: nil)
  end

  describe "#start_all!" do
    after { Rubino::Tools::Registry.reset! }

    it "starts a client per configured server and registers prefixed tools" do
      Rubino::Tools::Registry.reset!
      allow(RubyLLM::MCP).to receive(:client) do |**opts|
        opts[:name] == "filesystem" ? fake_client(%w[read_file write_file]) : fake_client(%w[query])
      end

      manager.start_all!

      expect(manager.clients.keys).to contain_exactly("filesystem", "api")
      expect(Rubino::Tools::Registry.find("filesystem_read_file")).to be_a(Rubino::MCP::MCPToolWrapper)
      expect(Rubino::Tools::Registry.find("filesystem_write_file")).to be_a(Rubino::MCP::MCPToolWrapper)
      expect(Rubino::Tools::Registry.find("api_query")).to be_a(Rubino::MCP::MCPToolWrapper)
    end

    it "passes the stdio command/args through to the client options" do
      allow(RubyLLM::MCP).to receive(:client).and_return(fake_client([]))

      manager.start_all!

      expect(RubyLLM::MCP).to have_received(:client).with(
        hash_including(
          name: "filesystem",
          transport_type: :stdio,
          config: { command: "fake-mcp-server", args: ["."], env: {} }
        )
      )
    end
  end

  describe "#start_server" do
    it "warns and returns nil when the client fails to start" do
      allow(RubyLLM::MCP).to receive(:client).and_raise(StandardError, "connection refused")

      result = manager.start_server("filesystem", raw["mcp"]["servers"]["filesystem"])

      expect(result).to be_nil
      expect(manager.clients).to be_empty
      warning = ui.messages.find { |m| m[:level] == :warning }
      expect(warning[:message]).to include("filesystem", "connection refused")
    end
  end

  describe "#tools_for_agent" do
    before do
      allow(RubyLLM::MCP).to receive(:client) do |**opts|
        opts[:name] == "filesystem" ? fake_client(%w[read_file]) : fake_client(%w[query])
      end
      manager.start_all!
    end

    after { Rubino::Tools::Registry.reset! }

    it "returns every server's tools for an :all agent" do
      definition = Rubino::Agent::Definition.new(name: "build", mcp_servers: :all)

      expect(manager.tools_for_agent(definition).map(&:name)).to contain_exactly("read_file", "query")
    end

    it "returns only the allowed servers' tools for a scoped agent" do
      definition = Rubino::Agent::Definition.new(name: "explore", mcp_servers: ["filesystem"])

      expect(manager.tools_for_agent(definition).map(&:name)).to eq(["read_file"])
    end

    it "returns no tools for an agent scoped to []" do
      definition = Rubino::Agent::Definition.new(name: "plan", mcp_servers: [])

      expect(manager.tools_for_agent(definition)).to be_empty
    end
  end

  describe "#health_check" do
    it "reports alive per started server" do
      allow(RubyLLM::MCP).to receive(:client) do |**opts|
        fake_client([], alive: opts[:name] == "filesystem")
      end
      manager.start_server("filesystem", raw["mcp"]["servers"]["filesystem"])
      manager.start_server("api", raw["mcp"]["servers"]["api"])

      expect(manager.health_check).to contain_exactly(
        { name: "filesystem", alive: true },
        { name: "api", alive: false }
      )
    end
  end

  describe "#configured?" do
    it "is true when mcp.servers is non-empty" do
      expect(manager.configured?).to be(true)
    end

    it "is false without any mcp.servers" do
      bare = described_class.new(config: Rubino::Config::Configuration.new(raw: {}, home_path: TEST_HOME))

      expect(bare.configured?).to be(false)
    end
  end
end
