# frozen_string_literal: true

# MCP section in `rubino tools` (#91, #94): configured servers produce a
# visible, prefixed tool listing; non-MCP users see no change at all.
RSpec.describe Rubino::CLI::ToolsCommand do
  let(:ui) { Rubino::UI::Null.new }

  before do
    Rubino.ui = ui
    Rubino::MCP.reset!
    Rubino::Tools::Registry.reset!
  end

  after do
    Rubino::MCP.reset!
    Rubino::Tools::Registry.reset!
  end

  def stub_configuration(raw)
    config = Rubino::Config::Configuration.new(raw: raw, home_path: TEST_HOME)
    allow(Rubino).to receive(:configuration).and_return(config)
  end

  def mcp_wrapper(server:, tool:)
    Rubino::MCP::MCPToolWrapper.new(
      double("mcp_tool", name: tool, description: "#{tool} tool"),
      server_name: server
    )
  end

  it "prints no MCP section when no servers are configured" do
    stub_configuration({})

    described_class.new.execute

    texts = ui.messages.map { |m| m[:message].to_s }
    expect(texts.grep(/MCP/)).to be_empty
  end

  it "lists prefixed MCP tools in their own table when servers are configured" do
    stub_configuration("mcp" => { "servers" => { "filesystem" => { "command" => "fake-mcp" } } })
    allow(Rubino::MCP).to receive(:boot!) do
      Rubino::Tools::Registry.register(mcp_wrapper(server: "filesystem", tool: "read_file"))
    end

    described_class.new.execute

    tables = ui.messages.select { |m| m[:level] == :table }
    expect(tables.size).to eq(2)

    builtin_rows, mcp_rows = tables.map { |t| t[:message][:rows] }
    # MCP wrappers must NOT leak into the builtin config-group table…
    expect(builtin_rows.map(&:first)).not_to include("filesystem_read_file")
    # …and must show up, prefixed and attributed to their server, in the MCP one.
    expect(mcp_rows).to eq([%w[filesystem_read_file filesystem]])
  end

  it "still prints a breadcrumb when servers are configured but no tools loaded" do
    stub_configuration("mcp" => { "servers" => { "filesystem" => { "command" => "fake-mcp" } } })
    allow(Rubino::MCP).to receive(:boot!).and_return(nil)

    described_class.new.execute

    texts = ui.messages.map { |m| m[:message].to_s }
    expect(texts.grep(/MCP Tools \(experimental\)/)).not_to be_empty
    expect(texts.grep(/no MCP tools loaded/)).not_to be_empty
  end
end
