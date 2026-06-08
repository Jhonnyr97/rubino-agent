# frozen_string_literal: true

RSpec.describe Rubino::Agent::DegenerateResponseRecovery do
  # Real AdapterResponse — the recovery reads #content, #thinking, #has_tool_calls?,
  # #input_tokens etc. No network: a plain value object.
  def response(content: nil, thinking: nil, tool_calls: [])
    Rubino::LLM::AdapterResponse.new(
      content: content, tool_calls: tool_calls, input_tokens: 1, output_tokens: 1,
      model_id: "fake", thinking: thinking
    )
  end

  def state(response:, streamed: "", messages: [], prior_content: nil, prior_hk: false)
    described_class::RecoveryState.new(
      response:                     response,
      streamed_text:                streamed,
      messages:                     messages,
      prior_turn_content:           prior_content,
      prior_tools_all_housekeeping: prior_hk
    )
  end

  subject(:recovery) { described_class.new }

  # ── Rung 1: partial-stream recovery ──────────────────────────
  describe "rung 1 — partial-stream recovery" do
    it "uses already-streamed visible content as the final response" do
      st = state(response: response(content: "<think>reasoning</think>"),
                 streamed: "<think>x</think>The delivered answer.")
      directive = recovery.recover(st)
      expect(directive.kind).to eq(:use)
      expect(directive.content).to eq("The delivered answer.")
    end

    it "does NOT fire when the streamed text is itself thinking-only" do
      st = state(response: response(content: "<think>reasoning</think>"),
                 streamed: "<think>still thinking</think>")
      expect(recovery.recover(st).kind).not_to eq(:use)
    end
  end

  # ── Rung 2: prior-turn content fallback ──────────────────────
  describe "rung 2 — prior-turn content fallback" do
    it "reuses prior-turn content when all prior tools were housekeeping" do
      st = state(response: response(content: "<think>nothing more</think>"),
                 prior_content: "You're welcome!", prior_hk: true)
      directive = recovery.recover(st)
      expect(directive.kind).to eq(:use)
      expect(directive.content).to eq("You're welcome!")
    end

    it "does NOT fire when prior tools were substantive (housekeeping flag false)" do
      st = state(response: response(content: "<think>nothing more</think>"),
                 prior_content: "I'll scan the directory…", prior_hk: false)
      expect(recovery.recover(st).kind).not_to eq(:use)
    end
  end

  # ── Rung 3: post-tool empty nudge ────────────────────────────
  describe "rung 3 — post-tool empty nudge" do
    let(:messages) do
      [{ role: "user", content: "do it" },
       { role: "assistant", content: "", tool_calls: [{ id: "1", name: "shell" }] },
       { role: "tool", content: "output", tool_call_id: "1" }]
    end

    it "appends an assistant + user nudge and asks to re-issue" do
      st = state(response: response(content: ""), messages: messages)
      directive = recovery.recover(st)

      expect(directive.kind).to eq(:nudge)
      # tool(result) → assistant("(empty)") → user(nudge): valid sequence.
      expect(messages[-2]).to include(role: "assistant", content: "(empty)")
      expect(messages.last[:role]).to eq("user")
      expect(messages.last[:content]).to eq(described_class::NUDGE_TEXT)
    end

    it "fires at most once per turn" do
      st = state(response: response(content: ""), messages: messages)
      expect(recovery.recover(st).kind).to eq(:nudge)
      # Second empty after the nudge must NOT nudge again — falls to retry.
      st2 = state(response: response(content: ""), messages: messages)
      expect(recovery.recover(st2).kind).to eq(:retry)
    end

    it "does NOT nudge a thinking-only response after a tool round — that routes to prefill" do
      st = state(response: response(content: "<think>working</think>"), messages: messages)
      expect(recovery.recover(st).kind).to eq(:prefill)
    end

    it "does NOT nudge when no recent tool message exists" do
      st = state(response: response(content: ""),
                 messages: [{ role: "user", content: "hi" }])
      expect(recovery.recover(st).kind).to eq(:retry)
    end
  end

  # ── Rung 4: thinking-only prefill-to-continue ×2 ──────────────
  describe "rung 4 — thinking-only prefill-to-continue" do
    it "prefills (twice) for an inline <think> response then exhausts to retry" do
      st = -> { state(response: response(content: "<think>deep reasoning</think>")) }

      d1 = recovery.recover(st.call)
      expect(d1.kind).to eq(:prefill)
      expect(d1.seed).to eq("deep reasoning") # seeds the model's own reasoning

      d2 = recovery.recover(st.call)
      expect(d2.kind).to eq(:prefill)

      # Third time: prefill budget (2) exhausted → empty retry.
      expect(recovery.recover(st.call).kind).to eq(:retry)
    end

    it "prefills for a structured thinking field (no inline tag)" do
      st = state(response: response(content: "", thinking: "structured chain of thought"))
      directive = recovery.recover(st)
      expect(directive.kind).to eq(:prefill)
      expect(directive.seed).to eq("structured chain of thought")
    end
  end

  # ── Rung 5: empty-content retry ×3 ───────────────────────────
  describe "rung 5 — empty-content retry" do
    it "retries a truly-empty response up to empty_max then raises" do
      recovery = described_class.new(empty_max: 3)
      empty = -> { state(response: response(content: "")) }

      expect(recovery.recover(empty.call)).to have_attributes(kind: :retry, attempt: 1)
      expect(recovery.recover(empty.call)).to have_attributes(kind: :retry, attempt: 2)
      expect(recovery.recover(empty.call)).to have_attributes(kind: :retry, attempt: 3)
      # Budget exhausted → terminal.
      expect(recovery.recover(empty.call).kind).to eq(:raise)
    end
  end

  # ── Rung 7: terminal ─────────────────────────────────────────
  describe "rung 7 — terminal" do
    it "raises (returns :raise) once the prefill AND empty budgets are spent" do
      r = described_class.new(prefill_max: 1, empty_max: 1)
      thinking = -> { state(response: response(content: "<think>x</think>")) }
      expect(r.recover(thinking.call).kind).to eq(:prefill) # 1 prefill
      expect(r.recover(thinking.call).kind).to eq(:retry)   # prefill exhausted → 1 empty retry
      expect(r.recover(thinking.call).kind).to eq(:raise)   # both spent
    end
  end
end
