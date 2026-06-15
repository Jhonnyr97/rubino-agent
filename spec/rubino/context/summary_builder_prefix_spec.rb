# frozen_string_literal: true

# #415c anti-replay guard: every compaction summary carries SUMMARY_PREFIX so
# the next context window treats it as reference-only, and the banner is never
# stacked when a previous (current or legacy) summary is re-compacted.
RSpec.describe Rubino::Context::SummaryBuilder do
  subject(:builder) { described_class.new(session_id: "s", config: test_configuration) }

  describe "#with_summary_prefix" do
    it "prepends the handoff banner to a bare summary" do
      out = builder.with_summary_prefix("## Active Task\nNone")
      expect(out).to start_with(described_class::SUMMARY_PREFIX)
      expect(out).to include("## Active Task")
    end

    it "does not stack the banner when it is already present" do
      once  = builder.with_summary_prefix("body")
      twice = builder.with_summary_prefix(once)
      expect(twice).to eq(once)
      expect(twice.scan("CONTEXT COMPACTION").size).to eq(1)
    end

    it "strips and re-normalizes the legacy [Compacted Summary] prefix" do
      legacy = "#{described_class::LEGACY_SUMMARY_PREFIX}\nold body"
      out = builder.with_summary_prefix(legacy)
      expect(out).to start_with(described_class::SUMMARY_PREFIX)
      expect(out).not_to include(described_class::LEGACY_SUMMARY_PREFIX)
      expect(out).to include("old body")
    end
  end

  describe "#strip_summary_prefix" do
    it "returns the body without the current banner" do
      withp = builder.with_summary_prefix("the body")
      expect(builder.strip_summary_prefix(withp)).to eq("the body")
    end
  end

  describe "#build" do
    let(:adapter) { instance_double(Rubino::LLM::RubyLLMAdapter) }

    before do
      allow(Rubino::LLM::RubyLLMAdapter).to receive(:new).and_return(adapter)
    end

    it "wraps the LLM summary in the anti-replay banner" do
      response = instance_double(Rubino::LLM::AdapterResponse, content: "## Active Task\nDo X")
      allow(adapter).to receive(:chat).and_return(response)

      out = builder.build(messages: [{ role: "user", content: "hi" }])
      expect(out).to start_with(described_class::SUMMARY_PREFIX)
      expect(out).to include("Do X")
    end

    it "wraps the fallback summary in the banner when the LLM fails" do
      allow(adapter).to receive(:chat).and_raise(StandardError, "boom")

      out = builder.build(messages: [{ role: "user", content: "hi" }])
      expect(out).to start_with(described_class::SUMMARY_PREFIX)
    end

    it "does not stack a banner when re-incorporating a previous summary" do
      prev = builder.with_summary_prefix("previous body")
      captured = nil
      allow(adapter).to receive(:chat) do |messages:|
        captured = messages.last[:content]
        instance_double(Rubino::LLM::AdapterResponse, content: "new")
      end

      builder.build(messages: [{ role: "user", content: "hi" }], previous_summary: prev)
      # The banner is stripped before the previous summary is fed back in.
      expect(captured).to include("previous body")
      expect(captured).not_to include("CONTEXT COMPACTION")
    end
  end
end
