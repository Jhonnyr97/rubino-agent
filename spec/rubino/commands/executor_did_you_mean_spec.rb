# frozen_string_literal: true

# FRICTION-4: an unknown slash command should suggest the CLOSEST known command
# ("Did you mean /status?") before the full roster, and the unguessable cancel
# syntax (`/agents <id> --stop`) should have a discoverable `/stop <id>` alias.
RSpec.describe Rubino::Commands::Executor do
  subject(:exec) { described_class.new(loader: loader, ui: ui) }

  let(:ui)     { Rubino::UI::Null.new }
  let(:loader) { Rubino::Commands::Loader.new(config: test_configuration) }

  before { allow(Rubino).to receive(:configuration).and_return(test_configuration) }

  def lines
    ui.messages.map { |m| m[:message].to_s }
  end

  # Inject a fake agents handler by pre-seeding the memo, so /stop routing can be
  # asserted without stubbing a method on the object under test.
  def stub_agents_handler
    fake = instance_double(Rubino::Commands::Handlers::Agents)
    exec.instance_variable_set(:@agents_handler, fake)
    fake
  end

  describe "did you mean (FRICTION-4)" do
    it "suggests the closest command on a one-char typo" do
      exec.try_execute("/stauts")
      expect(lines).to include(a_string_matching(%r{Did you mean /status\?}))
    end

    it "still lists the Available roster after the suggestion" do
      exec.try_execute("/stauts")
      expect(lines).to include(a_string_matching(/Available:/))
    end

    it "does not invent a suggestion for gibberish far from any command" do
      exec.try_execute("/zzzzqqqq")
      expect(lines).not_to include(a_string_matching(/Did you mean/))
      expect(lines).to include(a_string_matching(/Available:/))
    end
  end

  describe "/stop alias (FRICTION-4)" do
    it "is a registered built-in command" do
      expect(Rubino::Commands::BuiltIns::NAMES).to include("/stop")
    end

    it "routes /stop <id> to the agents stop path" do
      agents = stub_agents_handler
      expect(agents).to receive(:handle_stop_alias).with("abc123")
      expect(exec.try_execute("/stop abc123")).to eq(:handled)
    end

    it "teaches the usage on a bare /stop instead of erroring" do
      expect(exec.try_execute("/stop")).to eq(:handled)
      expect(lines).to include(a_string_matching(%r{/stop <id>}))
      expect(lines).not_to include(a_string_matching(/unknown command/))
    end
  end
end
