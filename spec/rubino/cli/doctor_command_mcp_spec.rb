# frozen_string_literal: true

# MCP section in doctor (#90): best-effort, informational, never fatal.
RSpec.describe Rubino::CLI::DoctorCommand do
  let(:doctor) { described_class.new }
  let(:ui) { Rubino::UI::Null.new }

  before { Rubino.ui = ui }

  def stub_configuration(raw)
    config = Rubino::Config::Configuration.new(raw: raw, home_path: TEST_HOME)
    allow(Rubino).to receive(:configuration).and_return(config)
  end

  def mcp_raw(servers)
    { "mcp" => { "servers" => servers }, "model" => { "default" => "test-model" } }
  end

  describe "#check_mcp_servers" do
    let(:servers) do
      {
        "filesystem" => { "transport" => "stdio", "command" => "fake-mcp" },
        "api" => { "transport" => "sse", "url" => "https://mcp.example.test" }
      }
    end

    it "reports per-server reachability and stops every server again" do
      stub_configuration(mcp_raw(servers))
      manager = instance_double(Rubino::MCP::Manager, start_server: nil, stop_all!: nil)
      allow(manager).to receive(:health_check).and_return(
        [{ name: "filesystem", alive: true }, { name: "api", alive: false }]
      )
      allow(Rubino::MCP::Manager).to receive(:new).and_return(manager)

      doctor.send(:check_mcp_servers)

      expect(manager).to have_received(:start_server).twice
      expect(manager).to have_received(:stop_all!)
      texts = ui.messages.map { |m| m[:message].to_s }
      expect(texts).to include("MCP server 'filesystem' reachable")
      expect(texts).to include("MCP server 'api' not reachable")
    end

    it "degrades any unexpected error to a warning (never raises)" do
      stub_configuration(mcp_raw(servers))
      allow(Rubino::MCP::Manager).to receive(:new).and_raise(StandardError, "boom")

      expect { doctor.send(:check_mcp_servers) }.not_to raise_error
      warning = ui.messages.find { |m| m[:level] == :warning }
      expect(warning[:message]).to include("MCP check failed", "boom")
    end
  end

  describe "#execute MCP wiring" do
    # All required checks are stubbed green so execute never reaches exit(1);
    # these examples only exercise the optional MCP section's gate.
    before do
      allow(doctor).to receive_messages(
        check_config: { name: "config", status: :ok },
        check_database: { name: "database", status: :ok },
        check_migrations: { name: "migrations", status: :ok },
        check_directories: { name: "directories", status: :ok },
        check_provider_keys: { name: "provider_keys", status: :ok },
        check_model_configured: { name: "model", status: :ok },
        check_encryption_key: { name: "encryption_key", status: :ok }
      )
    end

    it "skips the MCP section entirely when no servers are configured" do
      stub_configuration("model" => { "default" => "test-model" })
      expect(Rubino::MCP::Manager).not_to receive(:new)

      doctor.execute

      texts = ui.messages.map { |m| m[:message].to_s }
      expect(texts.grep(/MCP/)).to be_empty
    end

    it "reports a down MCP server without failing doctor (stays informational)" do
      stub_configuration(mcp_raw("filesystem" => { "command" => "fake-mcp" }))
      manager = instance_double(Rubino::MCP::Manager, start_server: nil, stop_all!: nil)
      allow(manager).to receive(:health_check).and_return([{ name: "filesystem", alive: false }])
      allow(Rubino::MCP::Manager).to receive(:new).and_return(manager)

      expect { doctor.execute }.not_to raise_error # no SystemExit

      texts = ui.messages.map { |m| m[:message].to_s }
      expect(texts).to include("MCP server 'filesystem' not reachable")
      expect(texts.grep(/All 6 checks passed/)).not_to be_empty
    end
  end
end
