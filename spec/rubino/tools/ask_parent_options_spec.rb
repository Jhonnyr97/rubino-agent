# frozen_string_literal: true

# ask_parent `options:` — the small, backward-compatible schema addition that
# lets a child supply concrete answer choices, surfaced as an arrow-select on
# the human's answer dropdown. Pins: the schema exposes an optional `options`
# array; a non-blocking ask records the normalized options on the entry; a bare
# ask (no options) records nil (old behaviour); junk/blank options normalize
# away.
RSpec.describe Rubino::Tools::AskParentTool do
  let(:tool)     { described_class.new }
  let(:registry) { Rubino::Tools::BackgroundTasks.instance }

  before { Rubino::Tools::BackgroundTasks.reset! }
  after  { Rubino::Tools::BackgroundTasks.reset! }

  describe "input_schema" do
    it "exposes an OPTIONAL `options` array of strings, not required" do
      props = tool.input_schema[:properties]
      expect(props).to have_key(:options)
      expect(props[:options][:type]).to eq("array")
      expect(props[:options][:items]).to eq(type: "string")
      expect(tool.input_schema[:required]).to eq(%w[question]) # options NOT required
    end
  end

  describe "options plumbing onto the blocked entry" do
    it "records the supplied options on the entry (non-blocking ask)" do
      child = registry.reserve(subagent: "explore", prompt: "x", owner_subagent_id: nil)
      Rubino.with_current_subagent_id(child.id) do
        tool.call("question" => "which db?", "blocking" => false, "options" => %w[sqlite postgres])
      end
      expect(registry.find(child.id).ask_options).to eq(%w[sqlite postgres])
      expect(registry.find(child.id).status).to eq(:blocked_on_human)
    end

    it "records nil when NO options are given (backward compatible)" do
      child = registry.reserve(subagent: "explore", prompt: "x", owner_subagent_id: nil)
      Rubino.with_current_subagent_id(child.id) do
        tool.call("question" => "open question?", "blocking" => false)
      end
      expect(registry.find(child.id).ask_options).to be_nil
    end

    it "normalizes blank / non-string options away" do
      child = registry.reserve(subagent: "explore", prompt: "x", owner_subagent_id: nil)
      Rubino.with_current_subagent_id(child.id) do
        tool.call("question" => "q", "blocking" => false, "options" => ["  ", "yes", "", :no])
      end
      expect(registry.find(child.id).ask_options).to eq(%w[yes no])
    end
  end

  describe "BackgroundTasks#begin_ask options default" do
    it "defaults options to nil so existing callers are unchanged" do
      entry = registry.reserve(subagent: "explore", prompt: "x")
      gate  = Rubino::Run::ApprovalGate.new
      gate.register("ask_#{entry.id}")
      registry.begin_ask(entry.id, gate: gate, ask_id: "ask_#{entry.id}",
                                   question: "q", blocking: true)
      expect(registry.find(entry.id).ask_options).to be_nil
    end
  end
end
