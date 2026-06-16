# frozen_string_literal: true

# #421 — auto-open the EXISTING approval / reply prompt for a pending subagent
# request. The REPL idle loop calls Handlers::Agents#auto_resolve_pending at
# every idle tick so a parked child's request presents ITSELF (the existing
# approve/deny/always prompt for an approval, the existing ◆ ask takeover for a
# free-form reply) instead of leaving a passive card the user must answer by
# guessing /agents <id> or /reply <id>. These specs pin the gate→prompt path:
# the auto-open resolves the SAME gate the manual slash command resolves, a
# request survives a turn interrupt (it is re-detected at the next idle), the
# manual slash fallback still works, and the security gate semantics (what
# requires approval) are untouched — only WHEN the prompt appears changes.
RSpec.describe Rubino::Commands::Handlers::Agents do
  # A scripted UI: records info/success/error lines, answers #ask (free-form
  # reply + the "why deny?" prompt) from +answers+, and the UNIFIED arrow-key
  # approval menu (TUI-6) from +decisions+ (decision symbols), so the auto-open
  # path is driven deterministically with no real TTY.
  let(:ui) do
    Class.new do
      attr_reader :lines

      def initialize(answers, decisions)
        @answers   = answers
        @decisions = decisions
        @lines     = []
      end

      def info(msg = "")    = @lines << msg.to_s
      def success(msg = "") = @lines << msg.to_s
      def error(msg = "")   = @lines << msg.to_s
      def separator         = nil
      def ask(_prompt)      = @answers.shift
      # The shared arrow-key approval component, scripted: pop the next queued
      # decision symbol (:once/:always_command/:no/:deny_explain) or nil.
      def subagent_approval_choice = @decisions.shift
      def respond_to_missing?(_name, _priv = false) = true
      def method_missing(_name, *_args) = nil
    end.new(answers, decisions)
  end

  let(:answers)   { [] }
  let(:decisions) { [] }
  let(:handler) { described_class.new(ui: ui) }
  let(:registry) { Rubino::Tools::BackgroundTasks.instance }

  before { Rubino::Tools::BackgroundTasks.reset! }
  after  { Rubino::Tools::BackgroundTasks.reset! }

  def stage_approval
    entry = registry.reserve(subagent: "explore", prompt: "do work")
    gate  = Rubino::Run::ApprovalGate.new
    gate.register("appr_#{entry.id}")
    registry.begin_approval(
      entry.id, gate: gate, approval_id: "appr_#{entry.id}",
                question: "run shell?", command: "rm -rf /tmp/x"
    )
    [entry, gate]
  end

  def stage_ask
    entry = registry.reserve(subagent: "explore", prompt: "do work")
    gate  = Rubino::Run::ApprovalGate.new
    gate.register("ask_#{entry.id}")
    registry.begin_ask(
      entry.id, gate: gate, ask_id: "ask_#{entry.id}",
                question: "sqlite or postgres?", blocking: true, owner_id: nil
    )
    [entry, gate]
  end

  describe "#auto_resolve_pending" do
    it "auto-opens the EXISTING approval prompt and resolves the child's gate" do
      _, gate = stage_approval
      decided = nil
      allow(gate).to receive(:decide) { |_id, v| decided = v }
      decisions << :once # the unified arrow-key menu — "Approve once" approves

      expect(handler.auto_resolve_pending).to be(true)
      expect(decided).to be(true) # the SAME gate the manual /agents <id> resolves
      # It showed the existing approval prompt body (no new widget/verb).
      expect(ui.lines.join("\n")).to include("needs approval to run:").and include("rm -rf /tmp/x")
    end

    it "deny through the auto-opened approval prompt resolves the gate to false" do
      _, gate = stage_approval
      decided = nil
      allow(gate).to receive(:decide) { |_id, v| decided = v }
      decisions << :no

      expect(handler.auto_resolve_pending).to be(true)
      expect(decided).to be(false)
    end

    # TUI-5: a NON-decision at the approval prompt (an aborted read / a stray
    # keystroke the menu can't resolve — formerly the silent-deny trap) RE-
    # PROMPTS instead of denying, and on a persistent non-answer leaves the
    # child PARKED (gate never decided) so /agents <id> re-opens it.
    it "re-prompts on a non-decision and never auto-denies (TUI-5)" do
      entry, gate = stage_approval
      allow(gate).to receive(:decide)
      decisions.push(nil, nil, nil) # three aborted reads in a row

      expect(handler.auto_resolve_pending).to be(true) # surfaced
      expect(gate).not_to have_received(:decide)       # NOT denied
      expect(registry.find(entry.id).status).to eq(:needs_approval) # still parked
      expect(ui.lines.join("\n")).to include("still waiting")
    end

    it "re-prompts then resolves when a decision finally arrives (TUI-5)" do
      _, gate = stage_approval
      decided = nil
      allow(gate).to receive(:decide) { |_id, v| decided = v }
      decisions.push(nil, :once) # one abort, then a real choice

      expect(handler.auto_resolve_pending).to be(true)
      expect(decided).to be(true)
    end

    it "auto-opens the EXISTING reply prompt and delivers the answer down the SAME wire" do
      entry, _gate = stage_ask
      answers << "use postgres" # the ◆ ask takeover's free-form answer
      expect(registry).to receive(:deliver_answer).with(entry.id, "use postgres").and_call_original

      expect(handler.auto_resolve_pending).to be(true)
      # The existing ◆ ask takeover body was shown (the reply affordance).
      expect(ui.lines.join("\n")).to include("asks").and include("sqlite or postgres?")
    end

    it "offers a pending APPROVAL before a pending REPLY (the more urgent gate)" do
      _appr, appr_gate = stage_approval
      _ask,  _ask_gate = stage_ask
      allow(appr_gate).to receive(:decide)
      decisions << :once

      handler.auto_resolve_pending
      # Approval body shown, reply body not yet (one request per call).
      joined = ui.lines.join("\n")
      expect(joined).to include("needs approval to run:")
      expect(joined).not_to include("sqlite or postgres?")
    end

    it "returns false (nothing presented) when no request is pending" do
      registry.reserve(subagent: "explore", prompt: "idle child")
      expect(handler.auto_resolve_pending).to be(false)
      expect(ui.lines).to be_empty
    end

    it "leaves the child waiting (no answer delivered) on an empty reply" do
      entry, _gate = stage_ask
      answers << "" # user dismissed the ◆ prompt without typing
      expect(registry).not_to receive(:deliver_answer)

      expect(handler.auto_resolve_pending).to be(true)
      expect(registry.find(entry.id).status).to eq(:blocked_on_human) # still pending
    end

    it "re-detects a request that survived a turn interrupt (still pending at next idle)" do
      entry, gate = stage_ask
      # Simulate a turn that interrupted/aborted: the request was NEVER answered,
      # so it is still :blocked_on_human and the next idle pass must re-surface it.
      expect(registry.find(entry.id).status).to eq(:blocked_on_human)
      answers << "postgres"
      allow(gate).to receive(:decide)

      expect(handler.auto_resolve_pending).to be(true) # surfaced, not lost
    end
  end

  describe "manual slash fallback still works (auto-open is additive)" do
    it "/reply <id> <answer> resolves a pending ask without the auto-open path" do
      entry, _gate = stage_ask
      expect(registry).to receive(:deliver_answer).with(entry.id, "postgres").and_call_original
      handler.handle_reply("#{entry.id} postgres")
    end
  end

  describe "security: the gate decides what requires approval, not the auto-open" do
    it "only surfaces children the policy already flipped to :needs_approval/:blocked_on_human" do
      # A plain running child (policy did NOT require approval) is NEVER auto-prompted.
      registry.reserve(subagent: "explore", prompt: "auto-runs allowlisted work")
      expect(handler.auto_resolve_pending).to be(false)
    end
  end
end
