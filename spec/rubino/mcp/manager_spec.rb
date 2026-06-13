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
    it "starts a client per configured server and registers prefixed tools" do
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

    # #182 — the /mcp drill-in answers "why is my server missing?" from the
    # recorded failure; a later successful start clears it.
    it "records the start failure in last_errors and clears it on success" do
      allow(RubyLLM::MCP).to receive(:client).and_raise(StandardError, "connection refused")
      manager.start_server("filesystem", raw["mcp"]["servers"]["filesystem"])
      expect(manager.last_errors["filesystem"]).to eq("connection refused")

      allow(RubyLLM::MCP).to receive(:client).and_return(fake_client([]))
      manager.start_server("filesystem", raw["mcp"]["servers"]["filesystem"])
      expect(manager.last_errors).not_to have_key("filesystem")
    end
  end

  # #182 — /mcp <server> off: stopping a server must ALSO drop its
  # MCPToolWrapper instances from Tools::Registry (before, nothing ever
  # unregistered them, so the model kept seeing tools whose client was gone).
  describe "#stop_server" do
    def start_both
      allow(RubyLLM::MCP).to receive(:client) do |**opts|
        opts[:name] == "filesystem" ? fake_client(%w[read_file]) : fake_client(%w[query])
      end
      manager.start_all!
    end

    it "stops the client, deregisters only ITS tools and emits :mcp_server_stopped" do
      start_both
      client = manager.clients["filesystem"]
      allow(Rubino.event_bus).to receive(:emit)

      manager.stop_server("filesystem")

      expect(client).to have_received(:stop)
      expect(manager.clients.keys).to eq(["api"])
      expect(Rubino::Tools::Registry.find("filesystem_read_file")).to be_nil
      expect(Rubino::Tools::Registry.find("api_query")).not_to be_nil
      expect(Rubino.event_bus).to have_received(:emit).with(:mcp_server_stopped, name: "filesystem")
    end

    it "returns nil for a server that is not running" do
      expect(manager.stop_server("filesystem")).to be_nil
    end

    it "stop_all! deregisters every server's tools" do
      start_both
      manager.stop_all!

      expect(manager.clients).to be_empty
      expect(Rubino::Tools::Registry.find("filesystem_read_file")).to be_nil
      expect(Rubino::Tools::Registry.find("api_query")).to be_nil
    end
  end

  # #182 — /mcp <server> on re-registers ONE server's tools without
  # re-reading every other client's tool list.
  describe "#register_server_tools" do
    it "registers only the named server's tools" do
      allow(RubyLLM::MCP).to receive(:client) do |**opts|
        opts[:name] == "filesystem" ? fake_client(%w[read_file]) : fake_client(%w[query])
      end
      manager.start_server("filesystem", raw["mcp"]["servers"]["filesystem"])
      manager.start_server("api", raw["mcp"]["servers"]["api"])

      manager.register_server_tools("filesystem")

      expect(Rubino::Tools::Registry.find("filesystem_read_file")).to be_a(Rubino::MCP::MCPToolWrapper)
      expect(Rubino::Tools::Registry.find("api_query")).to be_nil
    end
  end

  # Per-agent mcp_servers scoping is enforced in Agent::Definition#resolved_tools
  # (#173) — see definition_mcp_servers_spec.rb. The Manager only registers tools.

  # #174 — ruby_llm-mcp logs to $stdout by default, including every line a
  # stdio server prints on its stderr (relayed at INFO). That corrupted
  # one-shot `rubino prompt` output and polluted doctor/tools/chat boot.
  describe "MCP gem logging (#174)" do
    it "routes ruby_llm-mcp's logger to a file under the rubino home, never $stdout" do
      described_class.new(config: config)

      dev = RubyLLM::MCP.config.logger.instance_variable_get(:@logdev).dev
      expect(dev).not_to eq($stdout)
      # Resolve against the actual rubino home (default_home_path honours
      # RUBINO_HOME) rather than hardcoding TEST_HOME, so the spec passes under
      # any isolated home the suite is pointed at instead of assuming one.
      expect(dev.path)
        .to eq(File.join(Rubino::Config::Loader.default_home_path, "logs", "mcp.log"))
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
