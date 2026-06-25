# frozen_string_literal: true

# #Y3B — verb parity for memory delete across both surfaces. The REPL handler
# knew `/memory forget <id>`; the `rubino memory delete|forget` CLI accepted
# both verbs. These specs pin that the REPL now ALSO accepts `/memory delete`,
# routing it through the same confirm-then-forget path as `/memory forget`.
RSpec.describe Rubino::Commands::Handlers::Memory do
  let(:ui) do
    Class.new do
      attr_reader :lines, :successes

      def initialize
        @lines = []
        @successes = []
      end

      def info(msg = "")    = @lines << msg.to_s
      def error(msg = "")   = @lines << msg.to_s
      def success(msg = "") = @successes << msg.to_s
      def separator         = nil
      def confirm_destructive(_msg) = true # rubocop:disable Naming/PredicateMethod
      def respond_to_missing?(_name, _priv = false) = true
      def method_missing(_name, *_args) = nil
    end.new
  end

  let(:handler) { described_class.new(ui: ui) }
  let(:db_connection) { test_database }
  let(:db) { db_connection.db }
  let(:config) do
    test_configuration(
      "memory" => {
        "enabled" => true, "backend" => "sqlite",
        "user_profile_enabled" => true, "project_context_enabled" => true,
        "memory_char_limit" => 2200, "user_char_limit" => 1375,
        "sqlite" => { "vector" => false }
      }
    )
  end
  let(:backend) { Rubino::Memory::Backends::Sqlite.new(config: config, db: db) }

  before { allow(Rubino::Memory::Backends).to receive(:build).and_return(backend) }

  it "forgets a fact via `/memory forget <id>`" do
    row = backend.store(kind: "fact", content: "User's deploy port is 7788.")
    expect(backend.count).to eq(1)

    handler.handle_memory("forget #{row[:id][0..7]}")

    expect(backend.count).to eq(0)
    expect(ui.successes.join).to include("Forgot")
  end

  it "forgets a fact via the `/memory delete <id>` alias (#Y3B)" do
    row = backend.store(kind: "fact", content: "User's deploy port is 7788.")
    expect(backend.count).to eq(1)

    handler.handle_memory("delete #{row[:id][0..7]}")

    expect(backend.count).to eq(0)
    expect(ui.successes.join).to include("Forgot")
  end

  it "shows a delete-flavoured usage hint for a bare `/memory delete`" do
    handler.handle_memory("delete")
    expect(ui.lines.join).to include("Usage: /memory delete <id>")
  end
end
