# frozen_string_literal: true

require "tmpdir"
require "ruby_llm/mcp"

# Live check of the /mcp on/off/reload substrate (#182) against the REAL
# reference MCP stdio server (@modelcontextprotocol/server-filesystem via
# npx): stop_server must kill the client AND deregister its wrappers from
# Tools::Registry; start_server + register_server_tools must bring them back;
# stop_all!/start_all! (the reload path) must round-trip cleanly. Gated like
# the other live MCP smoke test:
#
#   LIVE_MCP=1 bundle exec rspec spec/rubino/mcp/mcp_live_onoff_spec.rb
RSpec.describe Rubino::MCP::Manager, :live_mcp do
  before do
    skip "set LIVE_MCP=1 to run the live MCP stdio on/off smoke test" unless ENV["LIVE_MCP"] == "1"
    Rubino::Tools::Registry.reset!
  end

  after { Rubino::Tools::Registry.reset! }

  def registered_wrappers
    Rubino::Tools::Registry.all.grep(Rubino::MCP::MCPToolWrapper)
  end

  it "off deregisters the server's tools, on re-registers them, reload round-trips" do
    Dir.mktmpdir("rubino-mcp-live-onoff") do |dir|
      server_config = {
        "transport" => "stdio",
        "command" => "npx",
        "args" => ["-y", "@modelcontextprotocol/server-filesystem", File.realpath(dir)]
      }
      raw = { "mcp" => { "servers" => { "filesystem" => server_config } } }
      config = Rubino::Config::Configuration.new(raw: raw, home_path: TEST_HOME)
      manager = described_class.new(config: config)

      # boot (the chat-start path)
      manager.start_all!
      expect(manager.health_check).to contain_exactly(hash_including(name: "filesystem", alive: true))
      expect(registered_wrappers).not_to be_empty

      # /mcp filesystem off — client gone AND tools deregistered
      manager.stop_server("filesystem")
      expect(manager.clients).to be_empty
      expect(registered_wrappers).to be_empty

      # /mcp filesystem on — client back, tools re-registered
      manager.start_server("filesystem", server_config)
      manager.register_server_tools("filesystem")
      expect(manager.health_check).to contain_exactly(hash_including(name: "filesystem", alive: true))
      expect(registered_wrappers.map(&:name)).to include("filesystem_read_text_file")

      # /mcp reload — stop_all! + start_all! round-trips
      manager.stop_all!
      expect(registered_wrappers).to be_empty
      manager.start_all!
      expect(registered_wrappers).not_to be_empty
      manager.stop_all!
    end
  end
end
