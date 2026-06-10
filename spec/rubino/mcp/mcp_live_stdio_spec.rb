# frozen_string_literal: true

require "tmpdir"
require "ruby_llm/mcp"

# Live end-to-end check against the REAL reference MCP stdio server
# (@modelcontextprotocol/server-filesystem via npx) — the exact setup the
# #170/#172 verification round used. Gated like the live MiniMax smoke test:
# needs node/npx and network for the first npx download, so it never runs in
# the default suite.
#
#   LIVE_MCP=1 bundle exec rspec spec/rubino/mcp/mcp_live_stdio_spec.rb
#
# rubocop:disable RSpec/BeforeAfterAll, RSpec/InstanceVariable -- one shared
# npx server process for all examples (read-only fixture, no state to leak);
# spawning a fresh server per example would only slow the gated run down.
RSpec.describe Rubino::MCP::MCPToolWrapper, :live_mcp do
  before(:all) do
    skip "set LIVE_MCP=1 to run the live MCP stdio smoke test" unless ENV["LIVE_MCP"] == "1"

    @fixture_dir = File.realpath(Dir.mktmpdir("rubino-mcp-live"))
    File.write(File.join(@fixture_dir, "project_notes.txt"), "Project build id: zebra-quark-9941\n")

    @client = RubyLLM::MCP.client(
      name: "filesystem",
      transport_type: :stdio,
      config: {
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", @fixture_dir],
        env: {}
      }
    )
  end

  after(:all) do
    @client&.stop
    FileUtils.rm_rf(@fixture_dir) if @fixture_dir
  end

  def wrapper_for(tool_name)
    tool = @client.tools.find { |t| t.name == tool_name }
    raise "tool #{tool_name} not advertised by the server" unless tool

    Rubino::MCP::MCPToolWrapper.new(tool, server_name: "filesystem")
  end

  it "forwards the server-declared input schema to the model (#170)" do
    schema = wrapper_for("read_text_file").input_schema

    expect(schema["properties"]).to have_key("path")
    expect(schema["required"]).to include("path")
  end

  it "returns the file content (not a validation error) for an outputSchema-bearing tool (#172)" do
    output = wrapper_for("read_text_file").call("path" => File.join(@fixture_dir, "project_notes.txt"))

    expect(output).to include("zebra-quark-9941")
    expect(output).not_to start_with("Error:")
  end

  it "maps a real server-side -32602 rejection onto the Error: convention (#172)" do
    output = wrapper_for("read_text_file").call("file_path" => "guessed-wrong-arg.txt")

    expect(output).to start_with("Error: MCP tool filesystem/read_text_file:")
  end
end
# rubocop:enable RSpec/BeforeAfterAll, RSpec/InstanceVariable
