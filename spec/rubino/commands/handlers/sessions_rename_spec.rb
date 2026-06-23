# frozen_string_literal: true

# #45 — a session is auto-titled from its first user message, so a throwaway
# first prompt ("say hi") becomes a useless, unidentifiable `/sessions` row.
# Both Hermes (/title) and Claude Code (rename) let the user fix this with an
# explicit rename. These specs pin `/sessions rename <id> <new title>`: it
# resolves the session with the SAME matcher resume/show/delete use and writes
# the new title through Session::Repository#update (which scrubs it).
RSpec.describe Rubino::Commands::Handlers::Sessions do
  let(:ui) do
    Class.new do
      attr_reader :lines

      def initialize = @lines = []
      def info(msg = "")    = @lines << msg.to_s
      def success(msg = "") = @lines << msg.to_s
      def error(msg = "")   = @lines << msg.to_s
      def table(**_kwargs) = nil
      def respond_to_missing?(_name, _priv = false) = true
      def method_missing(_name, *_args) = nil
    end.new
  end

  let(:handler) { described_class.new(ui: ui, runner: nil) }
  let(:repo) { Rubino::Session::Repository.new }
  let(:last_line) { ui.lines.last.to_s }

  # The handler builds its own Session::Repository off Rubino.database, so point
  # that at a fresh migrated in-memory DB. Set in `before` (not `around`) so it
  # runs AFTER the suite's global `before { Rubino.reset! }`, which would
  # otherwise drop the injected connection.
  before { Rubino.instance_variable_set(:@database, test_database) }

  it "renames a session resolved by id prefix and persists the new title" do
    session = repo.create(source: "cli", title: "say hi")

    result = handler.handle_sessions("rename #{session[:id][0, 8]} ship the release")

    expect(result).to eq(:handled)
    expect(repo.find(session[:id])[:title]).to eq("ship the release")
    expect(last_line).to match(/renamed/i)
  end

  it "teaches usage when no new title is given" do
    session = repo.create(source: "cli", title: "say hi")

    handler.handle_sessions("rename #{session[:id][0, 8]}")

    expect(last_line).to include("/sessions rename <id> <new title>")
    expect(repo.find(session[:id])[:title]).to eq("say hi")
  end

  it "reports a clean not-found for an unknown session" do
    handler.handle_sessions("rename nope-no-such a new name")

    expect(ui.lines.join("\n")).to match(/no session matching/i)
  end

  # S7 F3 — /status reads the runner's in-memory session[:title] snapshot.
  # Renaming the ACTIVE session must refresh that snapshot, else /status keeps
  # showing the stale auto-title until a compaction forks a new session id.
  it "refreshes the live runner's in-memory title when renaming the active session" do
    session = repo.create(source: "cli", title: "say hi")
    runner  = double("Runner", session: { id: session[:id], title: "say hi" })
    active_handler = described_class.new(ui: ui, runner: runner)

    active_handler.handle_sessions("rename #{session[:id][0, 8]} ship the release")

    expect(runner.session[:title]).to eq("ship the release")
  end

  it "leaves a non-active runner's in-memory title alone (only the renamed one)" do
    target = repo.create(source: "cli", title: "say hi")
    other  = repo.create(source: "cli", title: "other session")
    runner = double("Runner", session: { id: other[:id], title: "other session" })
    active_handler = described_class.new(ui: ui, runner: runner)

    active_handler.handle_sessions("rename #{target[:id][0, 8]} ship the release")

    expect(runner.session[:title]).to eq("other session")
    expect(repo.find(target[:id])[:title]).to eq("ship the release")
  end
end
