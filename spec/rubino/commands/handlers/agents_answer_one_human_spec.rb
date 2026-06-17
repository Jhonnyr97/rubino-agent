# frozen_string_literal: true

# Specs for the SHARED human-answer delivery used by BOTH the idle poll and the
# mid-turn auto-open: Handlers::Agents#answer_one_human / #answer_all_human and
# the options-or-free-text answer surface (#prompt_reply_answer). They pin:
#   * answer_one_human delivers via BackgroundTasks#deliver_answer (the ONE wire)
#     and never touches the parent turn's state;
#   * ask_parent `options:` → an arrow-SELECT of the options (+ a free-text
#     entry); absent → [Answer/Dismiss] → free-text (backward compatible);
#   * Esc / Dismiss / blank cancels the answer (child stays blocked);
#   * FIFO: answer_all_human delivers the head, re-reads awaiting_human, and
#     surfaces the next; a cancelled head doesn't loop forever;
#   * a timed-out / finished child → deliver_answer false → "not delivered".
RSpec.describe Rubino::Commands::Handlers::Agents do
  # A scripted UI: records info/error lines, answers #ask from +answers+, and
  # #select from +selections+ (popping the next queued chosen value, or nil for
  # an Esc/cancel). Mirrors the real CLI contract (select returns the value or
  # nil) so the options dropdown is driven deterministically with no TTY.
  let(:ui) do
    Class.new do
      attr_reader :lines, :select_prompts

      def initialize(answers, selections)
        @answers       = answers
        @selections    = selections
        @lines         = []
        @select_prompts = []
      end

      def info(msg = "")    = @lines << msg.to_s
      def success(msg = "") = @lines << msg.to_s
      def error(msg = "")   = @lines << msg.to_s
      def separator         = nil
      def ask(_prompt)      = @answers.shift

      def select(prompt, _choices)
        @select_prompts << prompt
        @selections.shift
      end

      def respond_to_missing?(_name, _priv = false) = true
      def method_missing(_name, *_args) = nil
    end.new(answers, selections)
  end

  let(:answers)    { [] }
  let(:selections) { [] }
  let(:handler)    { described_class.new(ui: ui) }
  let(:registry)   { Rubino::Tools::BackgroundTasks.instance }

  before { Rubino::Tools::BackgroundTasks.reset! }
  after  { Rubino::Tools::BackgroundTasks.reset! }

  def stage_ask(question: "sqlite or postgres?", options: nil)
    entry = registry.reserve(subagent: "explore", prompt: "do work")
    gate  = Rubino::Run::ApprovalGate.new
    gate.register("ask_#{entry.id}")
    registry.begin_ask(
      entry.id, gate: gate, ask_id: "ask_#{entry.id}",
                question: question, blocking: true, owner_id: nil, options: options
    )
    [entry, gate]
  end

  describe "#answer_one_human (free text, no options)" do
    it "offers [Answer/Dismiss], then delivers the typed answer down the SAME wire" do
      entry, = stage_ask
      selections << :answer # pick "✎ Answer (type)…"
      answers    << "use postgres"
      expect(registry).to receive(:deliver_answer).with(entry.id, "use postgres").and_call_original

      expect(handler.answer_one_human(entry)).to be(true)
      expect(ui.lines.join("\n")).to include("asks").and include("sqlite or postgres?")
    end

    it "Dismiss (or Esc → select nil) CANCELS — child stays blocked, nothing delivered" do
      entry, = stage_ask
      selections << nil # Esc / Dismiss
      expect(registry).not_to receive(:deliver_answer)

      expect(handler.answer_one_human(entry)).to be(true)
      expect(ui.lines.join("\n")).to include("still waiting")
      expect(registry.find(entry.id).status).to eq(:blocked_on_human) # still parked
    end
  end

  describe "#answer_one_human (with options)" do
    it "delivers the PICKED option verbatim" do
      entry, = stage_ask(options: %w[sqlite postgres])
      selections << "postgres" # arrow-selected option value
      expect(registry).to receive(:deliver_answer).with(entry.id, "postgres").and_call_original

      expect(handler.answer_one_human(entry)).to be(true)
      expect(ui.select_prompts.join).to include("Pick an answer")
    end

    it "the trailing free-text entry opens #ask for a custom answer" do
      entry, = stage_ask(options: %w[sqlite postgres])
      selections << :__free__ # the "✎ Answer (type)…" trailing entry
      answers    << "mysql actually"
      expect(registry).to receive(:deliver_answer).with(entry.id, "mysql actually").and_call_original

      expect(handler.answer_one_human(entry)).to be(true)
    end

    it "Esc on the options menu cancels — child stays blocked" do
      entry, = stage_ask(options: %w[sqlite postgres])
      selections << nil
      expect(registry).not_to receive(:deliver_answer)

      handler.answer_one_human(entry)
      expect(registry.find(entry.id).status).to eq(:blocked_on_human)
    end
  end

  describe "delivery decoupling (parent state untouched)" do
    it "routes ONLY through deliver_answer — decides the child gate, never the parent" do
      entry, gate = stage_ask
      decided = nil
      allow(gate).to receive(:decide) { |_id, v| decided = v }
      selections << :answer
      answers    << "go with sqlite"

      handler.answer_one_human(entry)
      expect(decided).to eq("go with sqlite") # the CHILD's gate, the one shared wire
    end

    it "a finished/timed-out child → deliver_answer false → 'not delivered'" do
      entry, = stage_ask
      selections << :answer
      answers    << "too late"
      # Simulate the child having finished between surfacing and delivery.
      allow(registry).to receive(:deliver_answer).with(entry.id, "too late").and_return(false)

      expect { handler.answer_one_human(entry) }.not_to raise_error
      expect(ui.lines.join("\n")).to include("not delivered")
    end
  end

  describe "#answer_all_human (FIFO drain)" do
    it "delivers the HEAD, then re-reads awaiting_human and surfaces the NEXT" do
      a, = stage_ask(question: "first?")
      b, = stage_ask(question: "second?")
      # Each head gets a free-text answer in order.
      selections.push(:answer, :answer)
      answers.push("answer-a", "answer-b")

      handler.answer_all_human

      expect(registry.find(a.id).status).to eq(:running) # delivered → unblocked
      expect(registry.find(b.id).status).to eq(:running)
      joined = ui.lines.join("\n")
      expect(joined).to include("first?").and include("second?")
    end

    it "stops (does not loop forever) when the head is CANCELLED" do
      stage_ask(question: "only?")
      selections << nil # cancel the head; it stays blocked

      expect { handler.answer_all_human }.not_to raise_error
      # Surfaced exactly once, then broke out (no infinite re-surface).
      expect(ui.lines.count { |l| l.include?("only?") }).to eq(1)
    end
  end

  describe "idle path unchanged (#auto_resolve_pending still delivers a human ask)" do
    it "auto-opens the reply affordance and delivers via the shared step" do
      entry, = stage_ask
      selections << :answer
      answers    << "postgres"
      expect(registry).to receive(:deliver_answer).with(entry.id, "postgres").and_call_original

      expect(handler.auto_resolve_pending).to be(true)
    end
  end
end
