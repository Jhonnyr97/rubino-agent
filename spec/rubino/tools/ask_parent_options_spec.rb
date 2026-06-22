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
    it "exposes an OPTIONAL `options` array (string OR {label, description}), not required" do
      props = tool.input_schema[:properties]
      expect(props).to have_key(:options)
      expect(props[:options][:type]).to eq("array")
      # Both shapes are accepted: a plain string, or a {label, description} map.
      shapes = props[:options][:items][:anyOf]
      expect(shapes.map { |s| s[:type] }).to contain_exactly("string", "object")
      map_shape = shapes.find { |s| s[:type] == "object" }
      expect(map_shape[:properties]).to have_key(:label)
      expect(map_shape[:required]).to eq(%w[label])
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

    # #475-3: a {label, description} map is normalized to {"label"=>, "description"=>}
    # (NOT a Ruby hash literal), so the picker can show a clean label + hint and
    # deliver the label string. A map with only a label collapses to that string.
    it "keeps {label, description} maps structured (no hash-literal coercion)" do
      child = registry.reserve(subagent: "explore", prompt: "x", owner_subagent_id: nil)
      Rubino.with_current_subagent_id(child.id) do
        tool.call("question" => "which db?", "blocking" => false, "options" => [
                    { "label" => "SQLite", "description" => "file-based, zero-setup" },
                    { "label" => "Postgres" }, # label-only collapses to a plain string
                    "MySQL" # plain strings still work
                  ])
      end
      sqlite = { "label" => "SQLite", "description" => "file-based, zero-setup" }
      expect(registry.find(child.id).ask_options).to eq([sqlite, "Postgres", "MySQL"])
    end

    it "drops a map with a blank/missing label" do
      child = registry.reserve(subagent: "explore", prompt: "x", owner_subagent_id: nil)
      Rubino.with_current_subagent_id(child.id) do
        tool.call("question" => "q", "blocking" => false, "options" => [
                    { "description" => "no label here" }, { "label" => "  " }, "ok"
                  ])
      end
      expect(registry.find(child.id).ask_options).to eq(%w[ok])
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

  # The authoritative parent notice (parent_sink.push_notice) is how the parent
  # MODEL learns of the question. It must NOT live inside the cosmetic CLI rescue:
  # if the CLI surfacing raises, the notice must still have fired — otherwise the
  # child blocks all the way to its timeout with the parent never told.
  describe "#surface_and_notify keeps the authoritative notice out of the cosmetic rescue" do
    let(:sink)  { double("ParentSink", push_notice: nil) }
    let(:entry) { double("Entry", parent_sink: sink, id: "t-1", subagent: "explore") }

    it "still pushes the parent notice even when the CLI surfacing raises" do
      # A parent_ui whose first surfacing call blows up — the cosmetic half.
      faulty_ui = Class.new(Rubino::UI::CLI) do
        def initialize; end # rubocop:disable Lint/MissingSuper
        def auto_open_human_ask(_entry) = raise("cli boom")
      end.new
      Rubino.instance_variable_set(:@ui, faulty_ui)

      expect { tool.send(:surface_and_notify, entry, "which db?") }.not_to raise_error
      # AUTHORITATIVE notice fired despite the cosmetic failure.
      expect(sink).to have_received(:push_notice).with(include("which db?"))
    ensure
      Rubino.instance_variable_set(:@ui, nil)
    end
  end
end
