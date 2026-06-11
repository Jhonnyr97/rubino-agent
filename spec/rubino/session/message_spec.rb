# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::Session::Message do
  describe "#to_context — paste expansion (#213)" do
    let(:token) { "[Pasted text #1 +8 lines]" }
    let(:body)  { (1..8).map { |i| "line #{i}" }.join("\n") }

    it "expands a stored paste placeholder into the FULL body for the model" do
      msg = described_class.new(
        session_id: "s1", role: "user",
        content: "before #{token} after",
        metadata: { paste_expansions: [[token, body]] }
      )
      ctx = msg.to_context
      expect(ctx[:content]).to eq("before #{body} after")
      expect(ctx[:content]).not_to include("[Pasted text")
    end

    it "leaves the stored content (the transcript echo) as the compact placeholder" do
      msg = described_class.new(
        session_id: "s1", role: "user",
        content: "before #{token} after",
        metadata: { paste_expansions: [[token, body]] }
      )
      # The DISPLAYED/persisted content keeps the placeholder — only to_context
      # (the model-facing view) expands it. This is what keeps resume clean.
      expect(msg.content).to eq("before #{token} after")
    end

    it "passes content through unchanged when there are no paste expansions" do
      msg = described_class.new(session_id: "s1", role: "user", content: "plain hello")
      expect(msg.to_context[:content]).to eq("plain hello")
    end

    it "survives a metadata JSON round-trip (tokens are not mangled into symbols)" do
      original = described_class.new(
        session_id: "s1", role: "user",
        content: token,
        metadata: { paste_expansions: [[token, body]] }
      )
      # Reload the way Session::Store#row_to_message does: JSON with symbolized
      # NAMES (keys), values intact — the array-of-pairs shape keeps the token
      # text whole.
      reloaded_meta = JSON.parse(
        JSON.generate(original.metadata), symbolize_names: true
      )
      reloaded = described_class.new(
        session_id: "s1", role: "user", content: token, metadata: reloaded_meta
      )
      expect(reloaded.to_context[:content]).to eq(body)
    end
  end
end
