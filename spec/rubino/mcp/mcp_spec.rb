# frozen_string_literal: true

RSpec.describe Rubino::MCP do
  let(:ui) { Rubino::UI::Null.new }

  before { Rubino.ui = ui }

  after { described_class.reset! }

  def config_with(raw)
    Rubino::Config::Configuration.new(raw: raw, home_path: TEST_HOME)
  end

  def stub_configuration(raw)
    allow(Rubino).to receive(:configuration).and_return(config_with(raw))
  end

  describe ".enabled?" do
    it "is false without an mcp block" do
      expect(described_class.enabled?(config_with({}))).to be(false)
    end

    it "is false with an empty servers map" do
      expect(described_class.enabled?(config_with("mcp" => { "servers" => {} }))).to be(false)
    end

    it "is true once a server is configured (configuring servers IS the opt-in)" do
      raw = { "mcp" => { "servers" => { "fs" => { "command" => "x" } } } }

      expect(described_class.enabled?(config_with(raw))).to be(true)
    end

    it "honors the mcp.enabled kill switch" do
      raw = { "mcp" => { "enabled" => false, "servers" => { "fs" => { "command" => "x" } } } }

      expect(described_class.enabled?(config_with(raw))).to be(false)
    end
  end

  describe ".boot!" do
    let(:configured_raw) { { "mcp" => { "servers" => { "fs" => { "command" => "x" } } } } }

    it "returns nil and builds no Manager when MCP is not enabled" do
      stub_configuration({})
      expect(Rubino::MCP::Manager).not_to receive(:new)

      expect(described_class.boot!).to be_nil
      expect(described_class.manager).to be_nil
    end

    it "starts the Manager once and memoizes it" do
      stub_configuration(configured_raw)
      manager = instance_double(Rubino::MCP::Manager, start_all!: {})
      allow(Rubino::MCP::Manager).to receive(:new).and_return(manager)

      expect(described_class.boot!).to be(manager)
      expect(described_class.boot!).to be(manager)
      expect(described_class.manager).to be(manager)
      expect(manager).to have_received(:start_all!).once
    end

    it "warns and returns nil when startup fails (never breaks boot)" do
      stub_configuration(configured_raw)
      manager = instance_double(Rubino::MCP::Manager)
      allow(manager).to receive(:start_all!).and_raise(StandardError, "spawn failed")
      allow(Rubino::MCP::Manager).to receive(:new).and_return(manager)

      expect(described_class.boot!).to be_nil
      warning = ui.messages.find { |m| m[:level] == :warning }
      expect(warning[:message]).to include("MCP startup failed", "spawn failed")
    end
  end

  # #182 — /mcp reload: stop everything, re-read config.yml, boot fresh, so a
  # server added to config becomes usable without restarting chat.
  describe ".reload!" do
    let(:configured_raw) { { "mcp" => { "servers" => { "fs" => { "command" => "x" } } } } }

    it "stops the old manager, re-reads config and boots a new one" do
      stub_configuration(configured_raw)
      allow(Rubino).to receive(:reload_configuration!)
      old_manager = instance_double(Rubino::MCP::Manager, start_all!: {}, stop_all!: nil)
      allow(Rubino::MCP::Manager).to receive(:new).and_return(old_manager)
      described_class.boot!

      new_manager = instance_double(Rubino::MCP::Manager, start_all!: {})
      allow(Rubino::MCP::Manager).to receive(:new).and_return(new_manager)

      expect(described_class.reload!).to be(new_manager)
      expect(old_manager).to have_received(:stop_all!)
      expect(Rubino).to have_received(:reload_configuration!)
      expect(described_class.manager).to be(new_manager)
    end

    it "returns nil (and keeps no manager) when the re-read config leaves MCP disabled" do
      stub_configuration({})
      allow(Rubino).to receive(:reload_configuration!)

      expect(described_class.reload!).to be_nil
      expect(described_class.manager).to be_nil
    end
  end
end
