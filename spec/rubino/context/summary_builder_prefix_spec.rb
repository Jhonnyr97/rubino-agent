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
  end

  describe "#strip_summary_prefix" do
    it "returns the body without the current banner" do
      withp = builder.with_summary_prefix("the body")
      expect(builder.strip_summary_prefix(withp)).to eq("the body")
    end
  end

  # The summary call routes through AuxiliaryClient so the WHOLE
  # `auxiliary.compression` block (provider/model/base_url) is honored — not just
  # the model id (the previous direct-adapter path silently ignored
  # provider/base_url). These stub AuxiliaryClient, the seam SummaryBuilder now
  # delegates to.
  describe "#build" do
    let(:aux_client) { instance_double(Rubino::LLM::AuxiliaryClient) }

    before do
      allow(Rubino::LLM::AuxiliaryClient).to receive(:new).and_return(aux_client)
    end

    it "routes the summary through AuxiliaryClient (task: compression) and wraps it in the banner" do
      response = instance_double(Rubino::LLM::AdapterResponse, content: "## Active Task\nDo X")
      allow(aux_client).to receive(:call).and_return(response)

      out = builder.build(messages: [{ role: "user", content: "hi" }])

      expect(aux_client).to have_received(:call).with(task: "compression", messages: anything)
      expect(out).to start_with(described_class::SUMMARY_PREFIX)
      expect(out).to include("Do X")
    end

    it "wraps the fallback summary in the banner when the aux call fails" do
      allow(aux_client).to receive(:call).and_raise(StandardError, "boom")

      out = builder.build(messages: [{ role: "user", content: "hi" }])
      expect(out).to start_with(described_class::SUMMARY_PREFIX)
    end

    it "does not stack a banner when re-incorporating a previous summary" do
      prev = builder.with_summary_prefix("previous body")
      captured = nil
      allow(aux_client).to receive(:call) do |**kw|
        captured = kw[:messages].last[:content]
        instance_double(Rubino::LLM::AdapterResponse, content: "new")
      end

      builder.build(messages: [{ role: "user", content: "hi" }], previous_summary: prev)
      # The banner is stripped before the previous summary is fed back in.
      expect(captured).to include("previous body")
      expect(captured).not_to include("CONTEXT COMPACTION")
    end

    it "passes the config through so AuxiliaryClient can honor the full auxiliary.compression block" do
      cfg = test_configuration(
        "auxiliary" => Rubino::Config::Defaults.to_hash["auxiliary"].merge(
          "compression" => { "provider" => "openai", "model" => "local-x",
                             "base_url" => "http://127.0.0.1:8000/v1", "timeout" => 120 }
        )
      )
      b = described_class.new(session_id: "s", config: cfg)
      allow(aux_client).to receive(:call).and_return(
        instance_double(Rubino::LLM::AdapterResponse, content: "ok")
      )

      b.build(messages: [{ role: "user", content: "hi" }])

      expect(Rubino::LLM::AuxiliaryClient).to have_received(:new).with(config: cfg)
    end
  end
end
