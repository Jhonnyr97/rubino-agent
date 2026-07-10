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

  def fake_client(tool_names, capabilities: {}, alive: true)
    caps = double("capabilities",
                  resources_list?: capabilities[:resources] || false,
                  prompt_list?: capabilities[:prompts] || false,
                  tools_list?: true)
    client = double("mcp_client",
                    tools: tool_names.map { |n| fake_tool(n) },
                    alive?: alive,
                    stop: nil,
                    capabilities: caps,
                    prompts: [],
                    resources: [])
    # notification handlers: keyword-safe no-op stubs so start_server always succeeds.
    # Ruby 3.x raises ArgumentError when a bare Proc.new{} receives keyword args,
    # so we absorb them with ** and ignore. Avoids interfering with spec stubs that
    # override these in helper methods like fake_client_with_notifications.
    allow(client).to receive(:on_logging) { |**_| client }
    allow(client).to receive(:on_progress) { |**_| client }
    client
  end

  describe "#start_all!" do
    it "starts a client per configured server and registers prefixed tools + resource tools" do
      allow(RubyLLM::MCP).to receive(:client) do |**opts|
        if opts[:name] == "filesystem"
          fake_client(%w[read_file write_file],
                      capabilities: { resources: true })
        else
          fake_client(%w[query],
                      capabilities: { resources: true })
        end
      end

      manager.start_all!

      expect(manager.clients.keys).to contain_exactly("filesystem", "api")
      expect(Rubino::Tools::Registry.find("filesystem_read_file")).to be_a(Rubino::MCP::MCPToolWrapper)
      expect(Rubino::Tools::Registry.find("filesystem_write_file")).to be_a(Rubino::MCP::MCPToolWrapper)
      expect(Rubino::Tools::Registry.find("api_query")).to be_a(Rubino::MCP::MCPToolWrapper)
      # Per-server resource tools
      expect(Rubino::Tools::Registry.find("filesystem_resources")).to be_a(Rubino::MCP::McpResourceTool)
      expect(Rubino::Tools::Registry.find("api_resources")).to be_a(Rubino::MCP::McpResourceTool)
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

    # #576 — servers are connected CONCURRENTLY (one thread each) so N hanging
    # servers cost ~the slowest single server, not the sum. A server that hangs
    # on connect must NOT prevent the others from starting and registering.
    it "isolates a hanging server: the others still start and register" do
      ready = Queue.new
      allow(RubyLLM::MCP).to receive(:client) do |**opts|
        if opts[:name] == "filesystem"
          ready.pop # block until the fast server has connected — proves concurrency
          fake_client(%w[read_file])
        else
          ready.push(:go) # api connects immediately, then unblocks filesystem
          fake_client(%w[query])
        end
      end

      manager.start_all!

      # Both completed despite filesystem only finishing AFTER api — they ran in
      # parallel, and no shared-state write was lost.
      expect(manager.clients.keys).to contain_exactly("filesystem", "api")
      expect(Rubino::Tools::Registry.find("filesystem_read_file")).to be_a(Rubino::MCP::MCPToolWrapper)
      expect(Rubino::Tools::Registry.find("api_query")).to be_a(Rubino::MCP::MCPToolWrapper)
      expect(manager.last_errors).to be_empty
    end

    # #576 — one server raising during connect is recorded in last_errors and
    # does not abort the parallel batch (best-effort boot preserved).
    it "records a per-server connect failure without blocking the healthy server" do
      allow(RubyLLM::MCP).to receive(:client) do |**opts|
        raise StandardError, "connection refused" if opts[:name] == "api"

        fake_client(%w[read_file])
      end

      manager.start_all!

      expect(manager.clients.keys).to eq(["filesystem"])
      expect(manager.last_errors["api"]).to eq("connection refused")
      expect(Rubino::Tools::Registry.find("filesystem_read_file")).to be_a(Rubino::MCP::MCPToolWrapper)
    end

    # #576 — @clients is populated in connect-COMPLETION order under parallelism,
    # so tool registration is sorted by server name to stay deterministic across
    # boots regardless of which server's connect finishes first.
    it "registers tools in a deterministic (sorted) server order" do
      allow(RubyLLM::MCP).to receive(:client) do |**opts|
        opts[:name] == "filesystem" ? fake_client(%w[read_file]) : fake_client(%w[query])
      end

      manager.start_all!

      registered = Rubino::Tools::Registry.all
                                          .grep(Rubino::MCP::MCPToolWrapper)
                                          .map(&:server_name)
      expect(registered).to eq(%w[api filesystem]) # sorted, not insertion order
    end

    # #576 — concurrent connects must not corrupt @clients / @last_errors: every
    # healthy client lands and nothing is dropped under the mutex. Use a wider
    # fan-out to make a missed write or torn Hash likely if the lock were absent.
    it "does not lose any client under many concurrent connects" do
      servers = (1..12).to_h { |i| ["s#{i}", { "transport" => "sse", "url" => "https://x.test/#{i}" }] }
      wide = Rubino::Config::Configuration.new(
        raw: { "mcp" => { "servers" => servers } }, home_path: TEST_HOME
      )
      mgr = described_class.new(config: wide)
      allow(RubyLLM::MCP).to receive(:client) { |**opts| fake_client(["#{opts[:name]}_tool"]) }

      mgr.start_all!

      expect(mgr.clients.keys).to match_array(servers.keys)
      expect(mgr.last_errors).to be_empty
    end

    # ── capability-gating (#prompts feature) ──

    it "registers a resource tool only when the server advertises resources capability" do
      allow(RubyLLM::MCP).to receive(:client) do |**opts|
        if opts[:name] == "filesystem"
          fake_client(%w[read_file], capabilities: { resources: true })
        else
          fake_client(%w[query])
        end
      end

      manager.start_all!

      expect(Rubino::Tools::Registry.find("filesystem_resources")).to be_a(Rubino::MCP::McpResourceTool)
      expect(Rubino::Tools::Registry.find("api_resources")).to be_nil
    end

    it "registers a prompt tool only when the server advertises prompts capability" do
      allow(RubyLLM::MCP).to receive(:client) do |**opts|
        if opts[:name] == "filesystem"
          fake_client(%w[read_file], capabilities: { prompts: true })
        else
          fake_client(%w[query])
        end
      end

      manager.start_all!

      expect(Rubino::Tools::Registry.find("filesystem_prompts")).to be_a(Rubino::MCP::McpPromptTool)
      expect(Rubino::Tools::Registry.find("api_prompts")).to be_nil
    end

    it "registers neither utility tool for a tools-only server (no resources/prompts capability)" do
      allow(RubyLLM::MCP).to receive(:client).and_return(fake_client(%w[query]))

      manager.start_all!

      expect(Rubino::Tools::Registry.find("filesystem_resources")).to be_nil
      expect(Rubino::Tools::Registry.find("api_resources")).to be_nil
      expect(Rubino::Tools::Registry.find("filesystem_prompts")).to be_nil
      expect(Rubino::Tools::Registry.find("api_prompts")).to be_nil
    end

    it "deregisters prompt tools alongside MCP wrappers when a server is stopped" do
      allow(RubyLLM::MCP).to receive(:client) do |**opts|
        if opts[:name] == "filesystem"
          fake_client(%w[read_file],
                      capabilities: { prompts: true })
        else
          fake_client(%w[query])
        end
      end
      manager.start_all!
      client = manager.clients["filesystem"]

      manager.stop_server("filesystem")

      expect(client).to have_received(:stop)
      expect(Rubino::Tools::Registry.find("filesystem_read_file")).to be_nil
      expect(Rubino::Tools::Registry.find("filesystem_prompts")).to be_nil
      expect(Rubino::Tools::Registry.find("api_query")).not_to be_nil
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

    # #dx — a STRING `args` (the natural YAML typo `args: "--root /data"`) used
    # to be passed straight to the MCP client, which iterated the string into
    # single characters, spawned a broken process, and surfaced ~8s later as a
    # misleading "timed out". It is now rejected IMMEDIATELY with a clear config
    # error — no client is ever constructed, so there is no hang.
    it "rejects a STRING `args` immediately with a clear message (no spawn, no hang)" do
      allow(RubyLLM::MCP).to receive(:client) # must NOT be called
      bad = { "transport" => "stdio", "command" => "fake-mcp-server", "args" => "--root /data" }

      result = manager.start_server("filesystem", bad)

      expect(result).to be_nil
      expect(RubyLLM::MCP).not_to have_received(:client)
      expect(manager.last_errors["filesystem"]).to match(/`args` must be a list.*String/m)
      warning = ui.messages.find { |m| m[:level] == :warning }
      expect(warning[:message]).to include("filesystem", "`args` must be a list")
    end

    it "accepts a nil `args` (defaults to []) and a list `args` unchanged" do
      allow(RubyLLM::MCP).to receive(:client).and_return(fake_client([]))

      manager.start_server("nolist", { "transport" => "stdio", "command" => "x" })
      expect(RubyLLM::MCP).to have_received(:client).with(
        hash_including(config: { command: "x", args: [], env: {} })
      )
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

    # ── notification handlers ──
    # Each started server gets on_logging / on_progress callbacks
    # that write to the MCP log file.

    def fake_client_with_notifications(tool_names, capabilities: {}, alive: true)
      captured = {}
      client = fake_client(tool_names, capabilities: capabilities, alive: alive)
      allow(client).to receive(:on_logging) do |_level: nil, &block|
        captured[:logging] = block
        client
      end
      allow(client).to receive(:on_progress) do |&block|
        captured[:progress] = block
        client
      end
      allow(client).to receive(:captured).and_return(captured)
      client
    end

    it "registers on_logging and on_progress handlers that write to the MCP log" do
      client = fake_client_with_notifications(%w[read_file])
      allow(RubyLLM::MCP).to receive(:client).and_return(client)

      # Replace the MCP logger with a StringIO so we can assert writes
      log_io = StringIO.new
      mcp_logger = Logger.new(log_io, level: Logger::DEBUG, progname: "test")
      allow(RubyLLM::MCP.config).to receive(:logger).and_return(mcp_logger)

      manager.start_server("filesystem", raw["mcp"]["servers"]["filesystem"])

      captured = client.captured
      expect(captured).to have_key(:logging)
      expect(captured).to have_key(:progress)

      # Fire the logging handler
      log_notification = double("notification",
                                params: { "level" => "info", "logger" => "mock-server",
                                          "data" => "scanning..." })
      captured[:logging].call(log_notification)
      log_io.rewind
      expect(log_io.read).to include("[filesystem] info: mock-server: scanning...")

      # Fire the progress handler
      progress = double("progress",
                        progress: 40, total: 100, message: "indexing files")
      captured[:progress].call(progress)
      log_io.rewind
      expect(log_io.read).to include("[filesystem] progress 40/100 — indexing files")
    end

    it "handles progress with nil total and nil message gracefully" do
      client = fake_client_with_notifications(%w[read_file])
      allow(RubyLLM::MCP).to receive(:client).and_return(client)

      log_io = StringIO.new
      mcp_logger = Logger.new(log_io, level: Logger::DEBUG)
      allow(RubyLLM::MCP.config).to receive(:logger).and_return(mcp_logger)

      manager.start_server("filesystem", raw["mcp"]["servers"]["filesystem"])

      progress = double("progress",
                        progress: 7, total: nil, message: nil)
      client.captured[:progress].call(progress)
      log_io.rewind
      expect(log_io.read).to include("[filesystem] progress 7")
      expect(log_io.read).not_to include("/")
      expect(log_io.read).not_to include("—")
    end

    it "server still starts and tools register when on_logging raises (feature unsupported)" do
      client = fake_client(%w[read_file])
      allow(client).to receive(:on_logging).and_raise(
        RubyLLM::MCP::Errors::UnsupportedFeature, "feature unsupported"
      )
      allow(RubyLLM::MCP).to receive(:client).and_return(client)

      log_io = StringIO.new
      mcp_logger = Logger.new(log_io, level: Logger::DEBUG)
      allow(RubyLLM::MCP.config).to receive(:logger).and_return(mcp_logger)

      manager.start_server("filesystem", raw["mcp"]["servers"]["filesystem"])

      expect(manager.clients).to have_key("filesystem")
      expect(manager.last_errors).not_to have_key("filesystem")
      log_io.rewind
      expect(log_io.read).to include("logging notifications unsupported")
    end

    it "server still starts and tools register when on_progress raises (feature unsupported)" do
      client = fake_client(%w[read_file])
      allow(client).to receive(:on_progress).and_raise(
        RubyLLM::MCP::Errors::UnsupportedFeature, "feature unsupported"
      )
      allow(RubyLLM::MCP).to receive(:client).and_return(client)

      log_io = StringIO.new
      mcp_logger = Logger.new(log_io, level: Logger::DEBUG)
      allow(RubyLLM::MCP.config).to receive(:logger).and_return(mcp_logger)

      manager.start_server("filesystem", raw["mcp"]["servers"]["filesystem"])

      expect(manager.clients).to have_key("filesystem")
      expect(manager.last_errors).not_to have_key("filesystem")
      log_io.rewind
      expect(log_io.read).to include("progress tracking unsupported")
    end
  end

  # #182 — /mcp <server> off: stopping a server must ALSO drop its
  # MCPToolWrapper instances from Tools::Registry (before, nothing ever
  # unregistered them, so the model kept seeing tools whose client was gone).
  describe "#stop_server" do
    def start_both
      allow(RubyLLM::MCP).to receive(:client) do |**opts|
        if opts[:name] == "filesystem"
          fake_client(%w[read_file],
                      capabilities: { resources: true })
        else
          fake_client(%w[query],
                      capabilities: { resources: true })
        end
      end
      manager.start_all!
    end

    it "stops the client, deregisters only ITS tools and resource tool, emits :mcp_server_stopped" do
      start_both
      client = manager.clients["filesystem"]
      allow(Rubino.event_bus).to receive(:emit)

      manager.stop_server("filesystem")

      expect(client).to have_received(:stop)
      expect(manager.clients.keys).to eq(["api"])
      expect(Rubino::Tools::Registry.find("filesystem_read_file")).to be_nil
      expect(Rubino::Tools::Registry.find("filesystem_resources")).to be_nil
      expect(Rubino::Tools::Registry.find("api_query")).not_to be_nil
      expect(Rubino::Tools::Registry.find("api_resources")).not_to be_nil
      expect(Rubino.event_bus).to have_received(:emit).with(:mcp_server_stopped, name: "filesystem")
    end

    it "returns nil for a server that is not running" do
      expect(manager.stop_server("filesystem")).to be_nil
    end

    it "stop_all! deregisters every server's tools and resource tools" do
      start_both
      manager.stop_all!

      expect(manager.clients).to be_empty
      expect(Rubino::Tools::Registry.find("filesystem_read_file")).to be_nil
      expect(Rubino::Tools::Registry.find("filesystem_resources")).to be_nil
      expect(Rubino::Tools::Registry.find("api_query")).to be_nil
      expect(Rubino::Tools::Registry.find("api_resources")).to be_nil
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

    # #575 — a connected-but-broken server (initialize OK, tools/list errors)
    # used to swallow the failure with only a warning, leaving /mcp's drill-in
    # with no last_error. Record it like start_server does.
    it "records last_errors when tools/list fails for an alive client" do
      broken = double("mcp_client", alive?: true, stop: nil)
      allow(broken).to receive(:tools).and_raise(StandardError, "Request timed out after 8 seconds")
      allow(broken).to receive_messages(on_logging: broken, on_progress: broken)
      allow(RubyLLM::MCP).to receive(:client).and_return(broken)
      manager.start_server("filesystem", raw["mcp"]["servers"]["filesystem"])

      manager.register_server_tools("filesystem")

      expect(manager.last_errors["filesystem"]).to eq("Request timed out after 8 seconds")
      expect(Rubino::Tools::Registry.find("filesystem_read_file")).to be_nil
    end

    it "clears a prior registration error once tools/list succeeds again" do
      allow(RubyLLM::MCP).to receive(:client).and_return(fake_client(%w[read_file]))
      manager.start_server("filesystem", raw["mcp"]["servers"]["filesystem"])
      manager.last_errors["filesystem"] = "old failure"

      manager.register_server_tools("filesystem")

      expect(manager.last_errors).not_to have_key("filesystem")
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
        { name: "filesystem", alive: true, degraded: false },
        { name: "api", alive: false, degraded: false }
      )
    end

    # #575 — an alive client whose tools/list errored (recorded last_error) is
    # PROTOCOL-broken: degraded, not a healthy "reachable".
    it "reports degraded for an alive client that recorded a registration error" do
      broken = double("mcp_client", alive?: true, stop: nil)
      allow(broken).to receive(:tools).and_raise(StandardError, "garbage")
      allow(broken).to receive_messages(on_logging: broken, on_progress: broken)
      allow(RubyLLM::MCP).to receive(:client).and_return(broken)
      manager.start_server("filesystem", raw["mcp"]["servers"]["filesystem"])
      manager.register_server_tools("filesystem")

      expect(manager.health_check)
        .to contain_exactly(hash_including(name: "filesystem", alive: true, degraded: true))
    end

    # An alive server that legitimately exposes ZERO tools (no error) is healthy,
    # NOT degraded — the degraded signal must come from a recorded error.
    it "does not mark an alive zero-tools server with no error as degraded" do
      allow(RubyLLM::MCP).to receive(:client).and_return(fake_client([]))
      manager.start_server("filesystem", raw["mcp"]["servers"]["filesystem"])
      manager.register_server_tools("filesystem")

      expect(manager.health_check)
        .to contain_exactly(hash_including(name: "filesystem", alive: true, degraded: false))
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
