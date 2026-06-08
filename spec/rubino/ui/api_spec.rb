# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::UI::API do
  let(:ui) { described_class.new }

  describe "agent-loop UI methods" do
    it "emits thinking_started as a recorded event (does not raise NotImplementedError)" do
      expect { ui.thinking_started }.not_to raise_error
      expect(ui.events.map { |e| e[:type] }).to include(:thinking_started)
    end

    it "emits note with text payload" do
      ui.note("turn · 1.2s · 0 tools")
      expect(ui.events.last[:type]).to eq(:note)
      expect(ui.events.last[:payload][:text]).to eq("turn · 1.2s · 0 tools")
    end

    it "emits tool_body with kind" do
      ui.tool_body("output", kind: :code)
      expect(ui.events.last[:type]).to eq(:tool_body)
      expect(ui.events.last[:payload]).to include(text: "output", kind: :code)
    end

    it "emits tool_chunk with name and chunk" do
      ui.tool_chunk("Bash", "hello\n")
      expect(ui.events.last[:type]).to eq(:tool_chunk)
      expect(ui.events.last[:payload]).to include(name: "Bash", chunk: "hello\n")
    end
  end

  describe "#confirm with session-scope cache" do
    # Minimal stand-ins for the real Gate/Recorder collaborators —
    # API only needs the surface API exercised here.
    let(:gate)     { double("gate") }
    let(:recorder) { double("recorder") }
    let(:cache)    { Rubino::Run::SessionApprovalCache.new }
    let(:api) do
      described_class.new(gate: gate, recorder: recorder,
                          session_id: "sess-1", approval_cache: cache)
    end

    it "remembers a session decision and skips the gate on the next confirm" do
      first_emitted  = false
      allow(gate).to receive(:register)
      allow(recorder).to receive(:emit) { first_emitted = true }
      allow(gate).to receive(:await).and_return("session")

      expect(api.confirm("Run rm -rf?", scope: "shell:rm -rf /tmp/cache")).to be(true)
      expect(first_emitted).to be(true)
      expect(cache.allowed?("sess-1", "shell:rm -rf /tmp/cache")).to be(true)

      # Second call — must NOT touch the gate or emit any approval.required.
      gate_called = false
      allow(gate).to receive(:register)     { gate_called = true }
      allow(gate).to receive(:await)        { gate_called = true }
      allow(recorder).to receive(:emit)     { gate_called = true }
      expect(api.confirm("Run rm -rf?", scope: "shell:rm -rf /tmp/cache")).to be(true)
      expect(gate_called).to be(false)
    end

    it "does NOT remember a once decision (caller must re-prompt next time)" do
      allow(gate).to receive(:register)
      allow(recorder).to receive(:emit)
      allow(gate).to receive(:await).and_return("once")

      api.confirm("Run rm -rf?", scope: "shell:rm -rf /tmp/cache")
      expect(cache.allowed?("sess-1", "shell:rm -rf /tmp/cache")).to be(false)
    end

    it "does NOT short-circuit when no scope is given (legacy callers)" do
      allow(gate).to receive(:register)
      allow(recorder).to receive(:emit)
      # First call: session-approve a scoped invocation
      allow(gate).to receive(:await).and_return("session")
      api.confirm("first", scope: "shell:rm")

      # Second call: no scope → must still prompt the gate.
      allow(gate).to receive(:await).and_return("deny")
      expect(api.confirm("second")).to be(false)
    end

    it "isolates scopes — approving shell:ls does NOT auto-approve shell:rm" do
      allow(gate).to receive(:register)
      allow(recorder).to receive(:emit)
      allow(gate).to receive(:await).and_return("session")
      api.confirm("ls?", scope: "shell:ls")

      # Different scope → still goes through the gate.
      allow(gate).to receive(:await).and_return("deny")
      expect(api.confirm("rm?", scope: "shell:rm")).to be(false)
    end
  end

  # W1: when the gate's wait deadline elapses with no human answer it hands
  # back the EXPIRED sentinel. API must treat that as a SAFE DENY for confirm
  # (the gated command must NOT run) and as "no answer" (nil) for ask — never
  # an auto-approve. The gate already emitted approval.expired.
  describe "#confirm / #ask on an expired (abandoned) gate" do
    let(:recorder) { double("recorder", emit: nil) }
    let(:gate) do
      double("gate", register: nil, await: Rubino::Run::ApprovalGate::EXPIRED)
    end
    let(:api) { described_class.new(gate: gate, recorder: recorder, session_id: "sess-x") }

    it "auto-DENIES confirm (does not approve, does not persist a rule)" do
      expect(Rubino::Security::AllowlistPersister).not_to receive(:persist)
      expect(api.confirm("Run rm -rf?", scope: "shell:rm -rf /tmp", command: "rm -rf /tmp")).to be(false)
    end

    it "returns nil from ask (treated as no clarification answer)" do
      expect(api.ask("Which approach?")).to be_nil
    end
  end

  describe "#confirm enriched approval.required payload" do
    let(:gate)     { double("gate", register: nil, await: "deny") }
    let(:emitted)  { [] }
    let(:recorder) { double("recorder") }
    let(:cache)    { Rubino::Run::SessionApprovalCache.new }
    let(:api) do
      described_class.new(gate: gate, recorder: recorder,
                          session_id: "sess-1", approval_cache: cache)
    end

    before do
      allow(recorder).to receive(:emit) { |type, payload| emitted << [type, payload] }
    end

    def confirm_payload(**kwargs)
      api.confirm("Allow shell?", **kwargs)
      type, payload = emitted.last
      expect(type).to eq("approval.required")
      payload
    end

    it "carries command/tool/hardline plus a derivable suggested_prefix and prefix choice" do
      payload = confirm_payload(scope: "shell:git status", tool: "shell", command: "git status")
      expect(payload[:command]).to eq("git status")
      expect(payload[:tool]).to eq("shell")
      expect(payload[:hardline]).to be(false)
      expect(payload[:suggested_prefix]).to eq("git")
      expect(payload[:pattern_key]).to be_nil
      expect(payload[:choices]).to eq(%w[once session always_prefix always_command deny deny_always])
    end

    it "omits always_prefix and suggested_prefix for a dangerous command (pattern, not prefix)" do
      payload = confirm_payload(scope: "shell:git push --force", tool: "shell",
                                command: "git push --force origin main",
                                pattern_key: "git force push (rewrites remote history)",
                                description: "git force push (rewrites remote history)")
      expect(payload[:suggested_prefix]).to be_nil
      expect(payload[:pattern_key]).to eq("git force push (rewrites remote history)")
      expect(payload[:description]).to eq("git force push (rewrites remote history)")
      expect(payload[:choices]).to eq(%w[once session always_command deny deny_always])
    end

    it "drops the session choice when no session id is wired" do
      api = described_class.new(gate: gate, recorder: recorder, approval_cache: cache)
      api.confirm("Allow?", scope: "shell:git status", tool: "shell", command: "git status")
      expect(emitted.last[1][:choices]).to eq(%w[once always_prefix always_command deny deny_always])
    end
  end

  describe "#confirm decision -> persistence mapping" do
    let(:gate)     { double("gate", register: nil) }
    let(:recorder) { double("recorder", emit: nil) }
    let(:cache)    { Rubino::Run::SessionApprovalCache.new }
    let(:api) do
      described_class.new(gate: gate, recorder: recorder,
                          session_id: "sess-1", approval_cache: cache)
    end

    def confirm_with(decision)
      allow(gate).to receive(:await).and_return(decision)
      api.confirm("Allow?", scope: "shell:git status", tool: "shell", command: "git status")
    end

    it "always_prefix persists the derived prefix to command_allowlist" do
      expect(Rubino::Security::AllowlistPersister).to receive(:persist).with("git")
      expect(confirm_with("always_prefix")).to be(true)
    end

    it "always_command persists the narrow (exact command) rule" do
      expect(Rubino::Security::AllowlistPersister).to receive(:persist).with("git status")
      expect(confirm_with("always_command")).to be(true)
    end

    it "the legacy 'always' alias persists the narrow rule (== always_command)" do
      expect(Rubino::Security::AllowlistPersister).to receive(:persist).with("git status")
      expect(confirm_with("always")).to be(true)
    end

    it "session is in-memory only — no persistence" do
      expect(Rubino::Security::AllowlistPersister).not_to receive(:persist)
      expect(confirm_with("session")).to be(true)
      expect(cache.allowed?("sess-1", "shell:git status")).to be(true)
    end

    it "once and deny never persist" do
      expect(Rubino::Security::AllowlistPersister).not_to receive(:persist)
      expect(confirm_with("once")).to be(true)
      expect(confirm_with("deny")).to be(false)
    end

    # --- deny semantics: once vs always ---

    it "plain deny is one-off — denies but persists NO deny rule (re-prompts next session)" do
      expect(Rubino::Security::DenyPersister).not_to receive(:persist)
      expect(Rubino::Security::AllowlistPersister).not_to receive(:persist)
      expect(confirm_with("deny")).to be(false)
      # Nothing remembered in-session either, so a fresh confirm still prompts.
      expect(cache.allowed?("sess-1", "shell:git status")).to be(false)
    end

    it "deny_always persists a permissions:deny rule (prefix-scoped) and still returns false" do
      expect(Rubino::Security::DenyPersister).to receive(:persist).with("shell git*")
      expect(confirm_with("deny_always")).to be(false)
    end
  end
end
