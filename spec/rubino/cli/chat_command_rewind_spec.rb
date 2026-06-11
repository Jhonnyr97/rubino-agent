# frozen_string_literal: true

# Behaviour specs for the Esc-Esc rewind (edit-and-resend) flow in ChatCommand:
# #handle_rewind opens a picker over the session's USER messages (most recent
# first), and a pick FORKS the session at the point BEFORE that message (the
# /branch copy-truncated infra), switches onto the fork, prints the dim
# `┄ rewound to message N — editing ┄` note, and pre-fills the composer with
# the message text. Esc-cancel leaves everything untouched.
RSpec.describe Rubino::CLI::ChatCommand do
  subject(:cmd) { described_class.new(provider: "fake", model: "fake/test") }

  let(:db)     { test_database }
  let(:config) { test_configuration }
  let(:ui)     { Rubino::UI::Null.new }
  let(:store)  { Rubino::Session::Store.new(db: db.db) }
  let(:repo)   { Rubino::Session::Repository.new(db: db.db) }
  let(:composer) do
    instance_double(Rubino::UI::BottomComposer, announce: nil, set_status: nil, prefill: nil)
  end
  # A persisted session with two full turns plus the user-role noise the picker
  # must NOT offer: a bang-shell injection and a tool result riding "user".
  let(:session) do
    s = repo.create(source: "cli", model: "fake/test", provider: "fake", title: "billing")
    s[:persisted] = true
    store.create(session_id: s[:id], role: "user", content: "wire up billing")
    store.create(session_id: s[:id], role: "assistant", content: "On it.")
    store.create(session_id: s[:id], role: "user", content: "<bash-input>ls</bash-input>")
    store.create(session_id: s[:id], role: "user", content: "now add stripe\nwith webhooks")
    store.create(session_id: s[:id], role: "assistant", content: "Done.")
    s
  end
  let(:runner) { instance_double(Rubino::Agent::Runner, session: session) }

  before do
    allow(Rubino).to receive_messages(database: db, configuration: config)
    Rubino.ui = ui
  end

  def rewind(chosen)
    allow(ui).to receive(:select).and_return(chosen)
    cmd.send(:handle_rewind, composer, runner, ui)
  end

  describe "#handle_rewind" do
    it "offers only REAL user messages, most recent first, as `N ago · snippet` rows" do
      captured = nil
      allow(ui).to receive(:select) do |_prompt, choices|
        captured = choices
        nil
      end

      cmd.send(:handle_rewind, composer, runner, ui)

      expect(captured.length).to eq(2) # the <bash-input> injection is excluded
      expect(captured[0][0]).to match(/\A\d+s ago · now add stripe with webhooks\z/) # newest first, flattened
      expect(captured[1][0]).to match(/\A\d+s ago · wire up billing\z/)
    end

    it "truncates long snippets to 60 chars" do
      store.create(session_id: session[:id], role: "user", content: "x" * 100)
      captured = nil
      allow(ui).to receive(:select) do |_prompt, choices|
        captured = choices
        nil
      end

      cmd.send(:handle_rewind, composer, runner, ui)

      expect(captured[0][0]).to end_with("#{"x" * 60}…")
    end

    it "forks BEFORE the picked message, switches onto the fork, leaves the original untouched" do
      # The picked message is "now add stripe…" — full-list index 3.
      new_runner = rewind(3)
      child = new_runner.session

      expect(child[:id]).not_to eq(session[:id])
      expect(child[:parent_session_id]).to eq(session[:id])
      # Truncated at the right point: everything BEFORE the picked message.
      expect(store.for_session(child[:id]).map(&:content))
        .to eq(["wire up billing", "On it.", "<bash-input>ls</bash-input>"])
      expect(repo.find(child[:id])[:message_count]).to eq(3)
      # The original is byte-for-byte untouched.
      expect(store.for_session(session[:id]).length).to eq(5)
      # The REPL adopts the fork on the next loop pass.
      expect(cmd.instance_variable_get(:@branch_short_id)).to eq(child[:id][0..3])
    end

    it "pre-fills the composer with the picked message text, multiline intact" do
      rewind(3)
      expect(composer).to have_received(:prefill).with("now add stripe\nwith webhooks")
      expect(composer).to have_received(:set_status)
    end

    it "prints the dim `rewound to message N — editing` note with the USER ordinal" do
      rewind(3) # the 2nd user message (the bash injection doesn't count)
      note = ui.messages.find { |m| m[:level] == :note }
      expect(note[:message]).to eq("rewound to message 2 — editing")
    end

    it "Esc-cancel changes nothing: no fork, no prefill, nil return" do
      session # materialize the lazy session row first
      before_sessions = repo.list.length

      expect(rewind(nil)).to be_nil

      expect(repo.list.length).to eq(before_sessions)
      expect(store.for_session(session[:id]).length).to eq(5)
      expect(composer).not_to have_received(:prefill)
    end

    it "announces (and never opens the picker) when there is nothing to rewind to" do
      empty = repo.create(source: "cli", model: "fake/test", provider: "fake")
      empty[:persisted] = true
      bare_runner = instance_double(Rubino::Agent::Runner, session: empty)
      allow(ui).to receive(:select)

      expect(cmd.send(:handle_rewind, composer, bare_runner, ui)).to be_nil

      expect(ui).not_to have_received(:select)
      expect(composer).to have_received(:announce).with("(no earlier message to rewind to)")
    end
  end
end
