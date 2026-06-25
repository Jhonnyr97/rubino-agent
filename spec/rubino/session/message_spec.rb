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

  # #583: a denied/errored tool row must replay to the model marked as an error
  # (is_error) on the next turn — derived from the persisted outcome (status /
  # error_code written by Agent::Loop#persist_tool_result), so resume sends the
  # SAME typed-error tool_result the live session sent.
  describe "#to_context — tool-result error flag (#583)" do
    def tool_msg(metadata)
      described_class.new(session_id: "s1", role: "tool", content: "BLOCKED ...",
                          tool_name: "chaos_add", tool_call_id: "toolu_1",
                          metadata: metadata)
    end

    it "flags a denied tool row as an error" do
      expect(tool_msg(status: "denied").to_context[:is_error]).to be(true)
    end

    it "flags an errored tool row as an error" do
      expect(tool_msg(status: "error").to_context[:is_error]).to be(true)
    end

    it "flags a soft-error tool row carrying an error_code" do
      expect(tool_msg(status: "success", error_code: "stale_read").to_context[:is_error]).to be(true)
    end

    it "does NOT flag a plain successful tool row" do
      expect(tool_msg(status: "success").to_context).not_to have_key(:is_error)
    end

    it "does NOT flag an old row that pre-dates the persisted outcome keys" do
      expect(tool_msg({}).to_context).not_to have_key(:is_error)
    end

    it "never flags a non-tool row" do
      msg = described_class.new(session_id: "s1", role: "user", content: "hi",
                                metadata: { status: "denied" })
      expect(msg.to_context).not_to have_key(:is_error)
    end
  end
end
