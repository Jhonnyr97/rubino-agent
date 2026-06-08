# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Rubino.with_ui (thread-scoped UI)" do
  let(:global_ui) { Rubino::UI::Null.new }
  let(:scoped_ui) { Rubino::UI::Null.new }

  before { Rubino.ui = global_ui }

  it "overrides Rubino.ui inside the block and restores it after" do
    expect(Rubino.ui).to be(global_ui)

    Rubino.with_ui(scoped_ui) do
      expect(Rubino.ui).to be(scoped_ui)
    end

    expect(Rubino.ui).to be(global_ui)
  end

  it "restores the previous value even when the block raises" do
    expect do
      Rubino.with_ui(scoped_ui) { raise "boom" }
    end.to raise_error("boom")

    expect(Rubino.ui).to be(global_ui)
  end

  it "nests: an inner scope restores the outer scope, not the global" do
    outer = Rubino::UI::Null.new
    inner = Rubino::UI::Null.new

    Rubino.with_ui(outer) do
      Rubino.with_ui(inner) { expect(Rubino.ui).to be(inner) }
      expect(Rubino.ui).to be(outer)
    end
  end

  it "does not leak the scoped UI into another thread (concurrent-run isolation)" do
    seen_in_other_thread = nil

    Rubino.with_ui(scoped_ui) do
      Thread.new { seen_in_other_thread = Rubino.ui }.join
    end

    # The sibling thread must see the global adapter, never this run's scoped UI.
    expect(seen_in_other_thread).to be(global_ui)
  end
end

RSpec.describe Rubino::Tools::QuestionTool do
  # Regression: the `question` tool reached for the gate-less process-global
  # Rubino.ui, so on the API path #ask returned nil and no clarify.required
  # was ever emitted (the web hung on an unanswerable question). It must use
  # whatever UI is currently in scope — including a run's thread-scoped gated UI.
  it "asks through the in-scope UI and returns the user's answer" do
    scoped_ui = Rubino::UI::Null.new
    allow(scoped_ui).to receive(:ask).and_return("riassunto tecnico")

    result = Rubino.with_ui(scoped_ui) do
      described_class.new.call("question" => "Che tipo di riassunto vuoi?")
    end

    expect(scoped_ui).to have_received(:ask).with("Che tipo di riassunto vuoi?")
    expect(result).to eq("User answered: riassunto tecnico")
  end
end
