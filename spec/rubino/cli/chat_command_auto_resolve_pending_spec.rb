# frozen_string_literal: true

# #450 INTEGRATION-PATH guard for the subagent auto-open.
#
# The handler-level spec (spec/rubino/commands/handlers/agents_auto_resolve_spec.rb)
# builds Rubino::Commands::Handlers::Agents directly from a scope where the
# constant already resolves, so it stayed GREEN while the feature was DEAD in
# the REPL. The death was upstream of the handler: ChatCommand#agents_request_handler
# referenced the UN-qualified `Commands::Handlers::Agents`, which lexically inside
# Rubino::CLI resolves to Rubino::CLI::Commands (the Thor class, no Handlers child)
# → NameError. The idle loop's wrapper (#auto_resolve_pending_subagent_request)
# rescued StandardError and returned false, so the NameError was swallowed on every
# ~50ms tick and the auto-open NEVER fired.
#
# These specs drive the REAL idle-loop entry point ChatCommand calls
# (#auto_resolve_pending_subagent_request -> #agents_request_handler), so they go
# RED on the bug (handler unreachable, no request surfaced, swallowed NameError)
# and GREEN on the fix (handler resolved, the existing pending request surfaced).
RSpec.describe Rubino::CLI::ChatCommand do
  subject(:cmd) { described_class.new(provider: "fake", model: "fake/test") }

  # A scripted UI mirroring the handler spec: records lines, answers #ask from
  # +answers+ and the unified arrow-key approval menu (TUI-6) from +decisions+,
  # so the auto-open path is driven deterministically, no TTY.
  let(:ui) do
    Class.new do
      attr_reader :lines

      def initialize(answers, decisions, budgets)
        @answers   = answers
        @decisions = decisions
        @budgets   = budgets
        @lines     = []
      end

      def info(msg = "")    = @lines << msg.to_s
      def success(msg = "") = @lines << msg.to_s
      def error(msg = "")   = @lines << msg.to_s
      def separator         = nil
      def ask(_prompt)      = @answers.shift
      # The reply affordance's options-or-text dropdown (#select): default to
      # :answer so the no-options [Answer/Dismiss] menu routes to the free-text
      # @ask the existing tests drive.
      def select(_prompt, _choices) = :answer
      def subagent_approval_choice = @decisions.shift
      def subagent_budget_choice   = @budgets.shift
      def respond_to_missing?(_name, _priv = false) = true
      def method_missing(_name, *_args) = nil
    end.new(answers, decisions, budgets)
  end

  let(:answers)   { [] }
  let(:decisions) { [] }
  let(:budgets)   { [] }
  let(:registry) { Rubino::Tools::BackgroundTasks.instance }

  before do
    Rubino.ui = ui
    Rubino::Tools::BackgroundTasks.reset!
  end

  after do
    Rubino::Tools::BackgroundTasks.reset!
    Rubino.ui = nil
  end

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

  def stage_budget(prompt: "do work")
    entry = registry.reserve(subagent: "explore", prompt: prompt)
    gate  = Rubino::Run::ApprovalGate.new
    gate.register("appr_#{entry.id}")
    registry.begin_approval(
      entry.id, gate: gate, approval_id: "appr_#{entry.id}",
                question: "Reached 13 tool iterations", command: "", budget: true
    )
    [entry, gate]
  end

  describe "#agents_request_handler (the constant the REPL resolves at idle)" do
    # The bug: this raised NameError (uninitialized constant
    # Rubino::CLI::Commands::Handlers) every time the idle loop touched it.
    it "resolves to the SAME handler the /agents slash command uses" do
      handler = cmd.send(:agents_request_handler)
      expect(handler).to be_a(Rubino::Commands::Handlers::Agents)
    end
  end

  describe "#auto_resolve_pending_subagent_request (the idle-loop hook)" do
    it "auto-opens the EXISTING approval prompt for a pending request" do
      _, gate = stage_approval
      decided = nil
      allow(gate).to receive(:decide) { |_id, v| decided = v }
      decisions << :once # the unified arrow-key menu — "Approve once" approves

      # On the bug this returned false (NameError swallowed); on the fix it
      # surfaces the request and resolves the SAME gate the manual path resolves.
      expect(cmd.send(:auto_resolve_pending_subagent_request)).to be(true)
      expect(decided).to be(true)
      expect(ui.lines.join("\n")).to include("needs approval to run:").and include("rm -rf /tmp/x")
    end

    it "returns false (nothing presented) when no request is pending" do
      registry.reserve(subagent: "explore", prompt: "idle child")
      expect(cmd.send(:auto_resolve_pending_subagent_request)).to be(false)
      expect(ui.lines).to be_empty
    end

    # #586: while the subagent picker is open it competes with this blocking
    # modal for stdin, so the auto-open DEFERS — the request stays pending and
    # surfaces on the next tick once the picker closes (never lost). Without the
    # guard the modal fires under the open picker and swallows the attach Enter.
    it "DEFERS (does not auto-open) while the subagent picker is open" do
      _, gate = stage_approval
      allow(gate).to receive(:decide)
      decisions << :once
      composer = instance_double(Rubino::UI::BottomComposer, agent_menu_open?: true)
      cmd.instance_variable_set(:@composer, composer)

      expect(cmd.send(:auto_resolve_pending_subagent_request)).to be(false)
      expect(gate).not_to have_received(:decide) # the gate was NOT touched
      expect(ui.lines).to be_empty               # no modal presented under the picker
    end

    it "auto-opens once the picker has closed (the deferred request is not lost)" do
      _, gate = stage_approval
      allow(gate).to receive(:decide)
      decisions << :once
      composer = instance_double(Rubino::UI::BottomComposer, agent_menu_open?: false)
      cmd.instance_variable_set(:@composer, composer)

      expect(cmd.send(:auto_resolve_pending_subagent_request)).to be(true)
      expect(gate).to have_received(:decide).with("appr_#{registry.list.first.id}", true)
    end

    # #586 residual — the destructive-keystroke footgun on the budget modal.
    # "Decide later" leaves the child PARKED (gate undecided) and snoozes the
    # auto-modal so a mis-aimed picker ↓+Enter can't force-summarize it.
    context "when a budget request is dismissed with 'Decide later' (#586 residual)" do
      it "does NOT decide the gate and SNOOZES the auto-modal" do
        entry, gate = stage_budget
        allow(gate).to receive(:decide)
        budgets << :later

        expect(cmd.send(:auto_resolve_pending_subagent_request)).to be(true)
        expect(gate).not_to have_received(:decide) # child stays parked
        expect(registry.find(entry.id).approval_snoozed).to be(true)
        expect(ui.lines.join("\n")).to include("left waiting")
      end

      it "stops re-popping the snoozed request at the next idle tick (no flicker loop)" do
        _, gate = stage_budget
        allow(gate).to receive(:decide)
        budgets << :later

        cmd.send(:auto_resolve_pending_subagent_request) # user picks "Decide later"
        ui.lines.clear
        # The very next tick must NOT re-present it (it's a parked card now).
        expect(cmd.send(:auto_resolve_pending_subagent_request)).to be(false)
        expect(ui.lines).to be_empty
      end

      it "still auto-opens a DIFFERENT (non-snoozed) pending request, skipping the snoozed one" do
        snoozed, gate1 = stage_budget(prompt: "snoozed child")
        allow(gate1).to receive(:decide)
        budgets << :later
        cmd.send(:auto_resolve_pending_subagent_request) # snooze the first
        ui.lines.clear

        _, gate2 = stage_approval # a fresh, non-snoozed approval behind it
        allow(gate2).to receive(:decide)
        decisions << :once

        expect(cmd.send(:auto_resolve_pending_subagent_request)).to be(true)
        expect(gate2).to have_received(:decide) # the non-snoozed one fired
        expect(registry.find(snoozed.id).approval_snoozed).to be(true) # the snoozed one stayed parked
      end

      it "grants budget normally when the user picks Grant (gate decided true)" do
        entry, gate = stage_budget
        decided = nil
        allow(gate).to receive(:decide) { |_id, v| decided = v }
        budgets << :grant

        expect(cmd.send(:auto_resolve_pending_subagent_request)).to be(true)
        expect(decided).to be(true)
        expect(registry.find(entry.id).approval_snoozed).to be(false)
      end
    end

    it "does NOT swallow a programming error (NameError) silently — it surfaces via the logger" do
      # The regression that hid #450: a NameError on every tick was invisible.
      # The hardened rescue logs the swallowed error ONCE at warn level so a future
      # coding error can never again hide a dead path forever.
      # Drive the error through the REAL handler the subject builds (don't stub
      # the subject itself): force its auto_resolve_pending to raise the very
      # NameError that the #450 bug produced on every idle tick.
      handler = cmd.send(:agents_request_handler)
      boom = NameError.new("uninitialized constant Rubino::CLI::Commands::Handlers")
      allow(handler).to receive(:auto_resolve_pending).and_raise(boom)

      logger = instance_double(Rubino::Logger)
      allow(Rubino).to receive(:logger).and_return(logger)
      expect(logger).to receive(:warn).once.with(
        hash_including(event: "chat.auto_resolve_pending.swallowed", error: "NameError")
      )

      # Idle loop still must not crash on the (now-logged) error, and the same
      # error fires only ONE warn even across many idle ticks (deduped).
      expect(cmd.send(:auto_resolve_pending_subagent_request)).to be(false)
      expect(cmd.send(:auto_resolve_pending_subagent_request)).to be(false)
    end
  end
end
