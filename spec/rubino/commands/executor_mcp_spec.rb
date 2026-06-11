# frozen_string_literal: true

# Load the MCP Manager up front so RubyLLM::MCP (required by manager.rb) is
# defined before the `before` block stubs it — otherwise this spec only ran
# coupled to a sibling that happened to load the Manager first.
require "rubino/mcp/manager"

# Covers the `/mcp` slash command (#182) — the in-chat MCP management surface,
# shaped like /skills: bare list, per-server drill-in, session-scoped on/off
# (off must ALSO deregister the server's wrappers from Tools::Registry), and
# reload. No network/subprocesses: RubyLLM::MCP.client is stubbed with the
# same doubles the Manager specs use; the Manager itself is real, so the
# stop/deregister/re-register paths are exercised end-to-end.
RSpec.describe Rubino::Commands::Executor do
  subject(:exec) { described_class.new(loader: loader, ui: ui) }

  let(:ui)     { Rubino::UI::Null.new }
  let(:loader) { Rubino::Commands::Loader.new(config: config) }

  let(:raw_servers) do
    {
      "filesystem" => { "transport" => "stdio", "command" => "fake-mcp", "args" => ["."] },
      "api" => { "transport" => "sse", "url" => "https://mcp.example.test/sse" }
    }
  end
  let(:config)  { test_configuration("mcp" => { "servers" => raw_servers }) }
  let(:manager) { Rubino::MCP::Manager.new(config: config) }

  before do
    Rubino.ui = ui
    allow(Rubino).to receive(:configuration).and_return(config)
    allow(RubyLLM::MCP).to receive(:client) do |**opts|
      opts[:name] == "filesystem" ? fake_client(%w[read_file write_file]) : fake_client(%w[query], alive: false)
    end
    manager.start_all!
    allow(Rubino::MCP).to receive(:manager).and_return(manager)
  end

  def fake_tool(name)
    double("mcp_tool", name: name, description: "#{name} tool")
  end

  def fake_client(tool_names, alive: true)
    double("mcp_client", tools: tool_names.map { |n| fake_tool(n) }, alive?: alive, stop: nil)
  end

  def output
    ui.messages.map { |m| m[:message].to_s }.join("\n")
  end

  describe "/mcp (list)" do
    it "lists each configured server with transport, reachability and tool count" do
      expect(exec.try_execute("/mcp")).to eq(:handled)
      expect(output).to include("filesystem", "(stdio)", "reachable", "2 tools")
      expect(output).to include("api", "(sse)", "down", "1 tool")
      expect(output).to include("/mcp <server> on|off", "/mcp reload")
    end

    it "marks a server with no live client as not started" do
      manager.clients.delete("api")
      exec.try_execute("/mcp")
      expect(output).to include("api", "(sse)", "not started")
    end
  end

  describe "empty states" do
    it "points at docs/mcp.md when no servers are configured" do
      allow(Rubino).to receive(:configuration).and_return(test_configuration)
      exec.try_execute("/mcp")
      expect(output).to include("No MCP servers configured", "docs/mcp.md")
    end

    it "explains the mcp.enabled kill switch" do
      disabled = test_configuration("mcp" => { "enabled" => false, "servers" => raw_servers })
      allow(Rubino).to receive(:configuration).and_return(disabled)
      exec.try_execute("/mcp")
      expect(output).to include("MCP is disabled (mcp.enabled: false")
    end
  end

  describe "/mcp <server> (drill-in)" do
    it "shows transport/target and the server's registered tools with descriptions" do
      exec.try_execute("/mcp filesystem")
      expect(output).to include("stdio", "fake-mcp .")
      expect(output).to include("filesystem_read_file", "read_file tool")
      expect(output).to include("filesystem_write_file")
      expect(output).not_to include("api_query")
    end

    it "shows the url target for a remote server" do
      exec.try_execute("/mcp api")
      expect(output).to include("sse", "https://mcp.example.test/sse")
    end

    it "shows the last start error for a server that failed to boot" do
      manager.last_errors["filesystem"] = "connection refused"
      exec.try_execute("/mcp filesystem")
      expect(output).to include("last error", "connection refused")
    end

    it "errors on an unknown server and lists the configured ones" do
      exec.try_execute("/mcp nope")
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("unknown MCP server: nope")
      expect(output).to include("filesystem", "api")
    end

    it "errors on an unknown action with usage" do
      exec.try_execute("/mcp filesystem frobnicate")
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("unknown /mcp action: frobnicate")
      expect(output).to include("/mcp filesystem [on|off]")
    end
  end

  describe "/mcp <server> off" do
    it "stops the client AND deregisters its wrappers (other servers untouched)" do
      client = manager.clients["filesystem"]
      exec.try_execute("/mcp filesystem off")

      expect(client).to have_received(:stop)
      expect(manager.clients).not_to have_key("filesystem")
      expect(Rubino::Tools::Registry.find("filesystem_read_file")).to be_nil
      expect(Rubino::Tools::Registry.find("filesystem_write_file")).to be_nil
      expect(Rubino::Tools::Registry.find("api_query")).not_to be_nil
      expect(output).to include("filesystem stopped", "2 tools removed")
    end

    it "is a friendly no-op when the server is not running" do
      manager.stop_server("filesystem")
      exec.try_execute("/mcp filesystem off")
      expect(output).to include("filesystem is not running")
    end
  end

  describe "/mcp <server> on" do
    it "restarts a stopped server and re-registers its tools" do
      exec.try_execute("/mcp filesystem off")
      expect(Rubino::Tools::Registry.find("filesystem_read_file")).to be_nil

      exec.try_execute("/mcp filesystem on")
      expect(manager.clients).to have_key("filesystem")
      expect(Rubino::Tools::Registry.find("filesystem_read_file")).to be_a(Rubino::MCP::MCPToolWrapper)
      expect(output).to include("filesystem started", "2 tools registered")
    end

    it "restarts (stop + start) a server that is already running" do
      old_client = manager.clients["filesystem"]
      exec.try_execute("/mcp filesystem on")
      expect(old_client).to have_received(:stop)
      expect(manager.clients["filesystem"]).not_to be(old_client)
    end

    it "reports a start failure without raising (warning carries the cause)" do
      exec.try_execute("/mcp filesystem off")
      allow(RubyLLM::MCP).to receive(:client).and_raise(StandardError, "spawn failed")

      exec.try_execute("/mcp filesystem on")
      expect(ui.messages.find { |m| m[:level] == :warning }[:message]).to include("spawn failed")
      expect(ui.messages.find { |m| m[:level] == :error }[:message]).to include("could not start MCP server")
    end
  end

  describe "/mcp reload" do
    it "reboots via MCP.reload! and lists the fresh state" do
      allow(Rubino::MCP).to receive(:reload!).and_return(manager)
      exec.try_execute("/mcp reload")
      expect(Rubino::MCP).to have_received(:reload!)
      expect(output).to include("MCP reloaded", "filesystem (stdio)")
    end

    it "works even when MCP is currently disabled (picks up a config edit)" do
      allow(Rubino).to receive(:configuration).and_return(test_configuration)
      allow(Rubino::MCP).to receive(:reload!).and_return(nil)
      exec.try_execute("/mcp reload")
      expect(Rubino::MCP).to have_received(:reload!)
      expect(output).to include("No MCP servers configured")
    end
  end

  describe "/status mcp line (#182/#186)" do
    it "shows servers · reachable · tools when MCP is enabled" do
      exec.try_execute("/status")
      expect(output).to match(%r{mcp\s+2 servers · 1 reachable · 3 tools\s+\(use /mcp\)})
    end

    it "says nothing about MCP when no servers are configured" do
      allow(Rubino).to receive(:configuration).and_return(test_configuration)
      exec.try_execute("/status")
      expect(output).not_to match(/^\s*mcp\s/)
    end
  end
end
