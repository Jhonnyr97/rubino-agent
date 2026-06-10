# frozen_string_literal: true

# Behaviour specs for the principal-chat probe + branch wiring in ChatCommand.
#   - `? `/`/probe`: run_probe runs a side-inference, renders the dim aside, and
#     does NOT mutate the parent session's message store;
#   - `/branch`: branch_runner forks the parent into a CHILD with
#     parent_session_id set, seeds the inherited context (+ a preceding probe
#     when present), leaves the parent untouched, and the returned runner is
#     switched onto the child.
RSpec.describe Rubino::CLI::ChatCommand do
  subject(:cmd) { described_class.new(provider: "fake", model: "fake/test") }

  let(:db)     { test_database }
  let(:config) { test_configuration }
  let(:ui)     { Rubino::UI::Null.new }
  let(:store)  { Rubino::Session::Store.new(db: db.db) }
  let(:repo)   { Rubino::Session::Repository.new(db: db.db) }
  # A real runner over the test DB, switched onto a persisted parent session
  # that already has a couple of turns.
  let(:parent_session) do
    s = repo.create(source: "cli", model: "fake/test", provider: "fake", title: "wire up billing")
    s[:persisted] = true
    store.create(session_id: s[:id], role: "user", content: "wire up billing")
    store.create(session_id: s[:id], role: "assistant", content: "On it.")
    s
  end
  let(:parent_runner) do
    instance_double(Rubino::Agent::Runner, session: parent_session)
  end

  before do
    allow(Rubino).to receive(:database).and_return(db)
    allow(Rubino).to receive(:configuration).and_return(config)
    Rubino.ui = ui
  end

  describe "#probe_question" do
    it "extracts the side-question from a leading `? ` line" do
      expect(cmd.send(:probe_question, "? is this MIT?")).to eq("is this MIT?")
    end

    it "does not treat a bare `?` or a normal line as a probe" do
      expect(cmd.send(:probe_question, "?")).to be_nil
      expect(cmd.send(:probe_question, "what is this?")).to be_nil
      expect(cmd.send(:probe_question, "?nospace")).to be_nil
    end
  end

  describe "#run_probe" do
    before do
      adapter = instance_double(
        Rubino::LLM::FakeProvider,
        chat: Rubino::LLM::AdapterResponse.new(
          content: "MIT.", tool_calls: [], input_tokens: 1, output_tokens: 1, model_id: "fake/test"
        )
      )
      allow(Rubino::LLM::AdapterFactory).to receive(:build).and_return(adapter)
    end

    it "renders the ephemeral aside and does NOT mutate the session store" do
      before_count = store.for_session(parent_session[:id]).size
      cmd.send(:run_probe, parent_runner, "is this MIT?", ui)

      aside = ui.messages.find { |m| m[:level] == :probe_aside }
      expect(aside[:message]).to eq("MIT.")
      expect(store.for_session(parent_session[:id]).size).to eq(before_count)
    end

    # #58: the probe wait shows the thinking indicator (on a TTY) and clears
    # it BEFORE the aside renders — the wait must never look frozen, and the
    # stale row must never glue onto the answer.
    it "brackets the wait with thinking started/finished on a TTY (#58)" do
      allow($stdout).to receive(:tty?).and_return(true)

      cmd.send(:run_probe, parent_runner, "is this MIT?", ui)

      levels = ui.messages.map { |m| m[:level] }
      expect(levels.index(:thinking_started)).to be < levels.index(:thinking_finished)
      expect(levels.index(:thinking_finished)).to be < levels.index(:probe_aside)
    end

    it "clears the indicator on a probe failure too (#58)" do
      allow($stdout).to receive(:tty?).and_return(true)
      allow(Rubino::LLM::AdapterFactory).to receive(:build).and_raise("boom")

      cmd.send(:run_probe, parent_runner, "is this MIT?", ui)

      levels = ui.messages.map { |m| m[:level] }
      expect(levels.index(:thinking_finished)).to be < levels.index(:warning)
      warning = ui.messages.find { |m| m[:level] == :warning }
      expect(warning[:message]).to include("probe failed")
    end

    it "shows no indicator off a TTY (piped)" do
      cmd.send(:run_probe, parent_runner, "is this MIT?", ui)

      expect(ui.messages.map { |m| m[:level] }).not_to include(:thinking_started)
    end
  end

  describe "#branch_runner" do
    # Switching onto the child rebuilds a real runner; stub history replay so we
    # don't depend on render details here (covered by the UI aside assertion).
    before { allow(cmd).to receive(:print_session_history) }

    it "forks a child with parent_session_id set, seeds inherited context, leaves the parent intact" do
      child_runner = cmd.send(:branch_runner, ui, parent_runner, "licensing-audit")
      child = child_runner.session

      expect(child[:parent_session_id]).to eq(parent_session[:id])
      expect(child[:title]).to eq("licensing-audit")
      # Inherited context: the parent's two messages are copied into the child.
      expect(store.for_session(child[:id]).map(&:content)).to eq(["wire up billing", "On it."])
      # Parent is untouched.
      expect(store.for_session(parent_session[:id]).map(&:content)).to eq(["wire up billing", "On it."])
      # The returned runner is switched onto the CHILD.
      expect(child[:id]).not_to eq(parent_session[:id])
    end

    it "promotes an immediately-preceding probe into the branch seed" do
      cmd.instance_variable_set(
        :@last_probe,
        Rubino::Interaction::Probe::Result.new(question: "is this MIT?", answer: "MIT, but bundles GPL.")
      )

      child_runner = cmd.send(:branch_runner, ui, parent_runner, "licensing-audit")
      seeded = store.for_session(child_runner.session[:id]).map(&:content)

      # Inherited context THEN the promoted probe Q&A.
      expect(seeded).to eq(["wire up billing", "On it.", "is this MIT?", "MIT, but bundles GPL."])
      # Parent still has only its own two messages — the aside never entered it.
      expect(store.for_session(parent_session[:id]).map(&:content)).to eq(["wire up billing", "On it."])

      conf = ui.messages.find { |m| m[:level] == :branch_confirmation }
      expect(conf[:message][:included_probe]).to be(true)
      expect(conf[:message][:parent_id]).to eq(parent_session[:id])
    end
  end
end
