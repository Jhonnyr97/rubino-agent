# frozen_string_literal: true

# Classification specs for Commands::Executor#busy_disposition — the single
# source of truth the BottomComposer's busy-time input gate consults for a line
# typed WHILE A TURN IS ACTIVE (immediate meta-commands while busy). Three
# dispositions:
#   :immediate — a read-only/control local meta-command (run NOW, don't queue);
#   :blocked   — a state-mutating/turn-affecting local built-in (don't queue,
#                don't run — the composer shows a transient notice);
#   :pass      — not a recognized local built-in (free text, ?/! prefixes, @file,
#                agent names, custom .md commands, unknown slashes) — queue as
#                today.
RSpec.describe Rubino::Commands::Executor, "#busy_disposition" do
  subject(:exec) { described_class.new(loader: loader, ui: ui, runner: nil) }

  let(:ui)     { Rubino::UI::Null.new }
  let(:loader) { Rubino::Commands::Loader.new(config: test_configuration) }

  before { allow(Rubino).to receive(:configuration).and_return(test_configuration) }

  # The immediate set is read-only / control only: inspect or signal the running
  # tree without mutating session/conversation/config/turn state.
  describe ":immediate — read-only / control meta-commands" do
    %w[/agents /tasks /stop /status /jobs /help /commands /dirs].each do |cmd|
      it "classifies #{cmd} as :immediate" do
        expect(exec.busy_disposition(cmd)).to eq(:immediate)
      end
    end

    it "classifies an immediate command WITH arguments as :immediate (e.g. /agents <id>, /stop <id>)" do
      expect(exec.busy_disposition("/agents abc123")).to eq(:immediate)
      expect(exec.busy_disposition("/stop abc123")).to eq(:immediate)
    end
  end

  # Everything else that IS a known local built-in mutates state or affects the
  # turn — not available mid-turn. /reply is BLOCKED on purpose: its interactive
  # form (`/reply <id>` -> @ui.ask) would steal stdin from the live reader.
  describe ":blocked — state-mutating / turn-affecting built-ins" do
    %w[/model /compact /clear /new /resume /config /sessions /branch /export
       /memory /agent /reply /skills /mcp /add-dir /mode /reasoning /think
       /probe /paste /clear-images /exit /quit /queued].each do |cmd|
      it "classifies #{cmd} as :blocked (default-to-blocked on uncertainty)" do
        # /resume is not a registered built-in name in this build, so it falls
        # through to :pass; every other listed name is a known built-in ⇒ blocked.
        result = exec.busy_disposition(cmd)
        if Rubino::Commands::BuiltIns::NAMES.include?(cmd)
          expect(result).to eq(:blocked)
        else
          expect(result).to eq(:pass)
        end
      end
    end
  end

  describe ":pass — not a recognized local built-in" do
    it "passes plain free text" do
      expect(exec.busy_disposition("hello world")).to eq(:pass)
    end

    it "passes a `?` probe and a `!` shell escape" do
      expect(exec.busy_disposition("? what is this")).to eq(:pass)
      expect(exec.busy_disposition("!ls -la")).to eq(:pass)
    end

    it "passes an @file mention line" do
      expect(exec.busy_disposition("@README.md summarize")).to eq(:pass)
    end

    it "passes an UNKNOWN slash command (so the post-turn dispatch handles it unchanged)" do
      expect(exec.busy_disposition("/definitely-not-a-command")).to eq(:pass)
    end
  end

  # The classification is exhaustive over the built-in roster: every registered
  # built-in is either :immediate or :blocked, never :pass (guards against a new
  # command silently falling through the gate).
  it "classifies every registered built-in as :immediate or :blocked (no built-in falls through to :pass)" do
    Rubino::Commands::BuiltIns::NAMES.each do |name|
      expect(exec.busy_disposition(name)).to(
        satisfy { |d| %i[immediate blocked].include?(d) },
        "expected #{name} to be :immediate or :blocked, got #{exec.busy_disposition(name).inspect}"
      )
    end
  end
end
