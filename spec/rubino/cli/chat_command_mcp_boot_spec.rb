# frozen_string_literal: true

# Chat boot wiring (#91/#95): ensure_setup! boots MCP (the gate itself —
# servers configured + mcp.enabled — lives in MCP.boot!/enabled?).
RSpec.describe Rubino::CLI::ChatCommand do
  let(:command) { described_class.new({}) }

  it "boots MCP during ensure_setup!" do
    allow(command).to receive(:ensure_database_ready!)
    allow(Rubino).to receive(:agent_registry)
    allow(Rubino::Tools::Registry).to receive(:all).and_return([:populated])
    allow(Rubino::MCP).to receive(:boot!)

    command.send(:ensure_setup!)

    expect(Rubino::MCP).to have_received(:boot!)
  end
end
