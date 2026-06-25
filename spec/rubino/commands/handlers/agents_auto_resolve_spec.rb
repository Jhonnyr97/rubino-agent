# frozen_string_literal: true

# #421 — auto-open the EXISTING approval prompt for a pending subagent
# request. The REPL idle loop calls Handlers::Agents#auto_resolve_pending at
# every idle tick so a parked child's request presents ITSELF (the existing
# approve/deny/always prompt for an approval) instead of leaving a passive
# card the user must answer by guessing /agents <id>. These specs pin the
# gate→prompt path:
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

      def initialize(answers, decisions, selections = [])
        @answers    = answers
        @decisions  = decisions
        @selections = selections
        @lines      = []
      end

      def info(msg = "")    = @lines << msg.to_s
      def success(msg = "") = @lines << msg.to_s
      def error(msg = "")   = @lines << msg.to_s
      def separator         = nil
      def ask(_prompt)      = @answers.shift
      # The reply affordance's options-or-text dropdown (#select), scripted: pop
      # the next queued selection, defaulting to :answer so the no-options
      # [Answer/Dismiss] menu routes straight to the free-text @ask the existing
      # tests drive (so the reply flow is unchanged unless a test scripts a pick).
      def select(_prompt, _choices) = @selections.empty? ? :answer : @selections.shift
      # The shared arrow-key approval component, scripted: pop the next queued
      # decision symbol (:once/:always_command/:no/:deny_explain) or nil.
      def subagent_approval_choice = @decisions.shift
      def respond_to_missing?(_name, _priv = false) = true
      def method_missing(_name, *_args) = nil
    end.new(answers, decisions, selections)
  end

  let(:answers)    { [] }
  let(:decisions)  { [] }
  let(:selections) { [] }
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

    it "returns false (nothing presented) when no request is pending" do
      registry.reserve(subagent: "explore", prompt: "idle child")
      expect(handler.auto_resolve_pending).to be(false)
      expect(ui.lines).to be_empty
    end

    # R2 — two children raise an approval at once. Only ONE modal is presented
    # per call (the FIFO head); it advertises "(1 more queued)" so the user knows
    # the second is waiting, and resolving the first lets the second present
    # (with no backlog) on the next idle pass. The modals never overlap.
    it "presents ONE approval modal at a time and advertises the queued backlog (R2)" do
      first, first_gate   = stage_approval
      second, second_gate = stage_approval
      allow(first_gate).to receive(:decide)
      allow(second_gate).to receive(:decide)

      # The FIFO head is the child that parked FIRST.
      expect(registry.awaiting_approval.first.id).to eq(first.id)

      decisions << :once
      handler.auto_resolve_pending
      joined = ui.lines.join("\n")
      # The active modal is the head AND it tells the user another is queued.
      expect(joined).to include(first.id).and include("(1 more queued)")
      # The SECOND child's modal body did NOT render — no overlap.
      expect(joined).not_to include("(0 more queued)")
      expect(first_gate).to have_received(:decide)
      expect(second_gate).not_to have_received(:decide)

      # The child's approval handler clears the gate state in its ensure once the
      # decision is delivered; simulate that resume so the entry leaves the queue.
      registry.end_approval(first.id)

      # After the first resolves it is no longer parked; the second is now the
      # sole head with no backlog, and the NEXT idle pass presents it.
      ui.lines.clear
      decisions << :once
      handler.auto_resolve_pending
      joined2 = ui.lines.join("\n")
      expect(joined2).to include(second.id)
      expect(joined2).not_to include("more queued")
      expect(second_gate).to have_received(:decide)
    end
  end

  describe "security: the gate decides what requires approval, not the auto-open" do
    it "only surfaces children the policy already flipped to :needs_approval" do
      # A plain running child (policy did NOT require approval) is NEVER auto-prompted.
      registry.reserve(subagent: "explore", prompt: "auto-runs allowlisted work")
      expect(handler.auto_resolve_pending).to be(false)
    end
  end
end
