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
      def subagent_approval_choice = @decisions.shift
      def respond_to_missing?(_name, _priv = false) = true
      def method_missing(_name, *_args) = nil
    end.new(answers, decisions)
  end

  let(:answers)   { [] }
  let(:decisions) { [] }
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

  describe "#agents_request_handler (the constant the REPL resolves at idle)" do
    # The bug: this raised NameError (uninitialized constant
    # Rubino::CLI::Commands::Handlers) every time the idle loop touched it.
    it "resolves to the SAME handler the /agents and /reply slash commands use" do
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

    it "auto-opens the EXISTING reply prompt and delivers the answer down the SAME wire" do
      entry, _gate = stage_ask
      answers << "use postgres"
      expect(registry).to receive(:deliver_answer).with(entry.id, "use postgres").and_call_original

      expect(cmd.send(:auto_resolve_pending_subagent_request)).to be(true)
      expect(ui.lines.join("\n")).to include("asks").and include("sqlite or postgres?")
    end

    it "returns false (nothing presented) when no request is pending" do
      registry.reserve(subagent: "explore", prompt: "idle child")
      expect(cmd.send(:auto_resolve_pending_subagent_request)).to be(false)
      expect(ui.lines).to be_empty
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
