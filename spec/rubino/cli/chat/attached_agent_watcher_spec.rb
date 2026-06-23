# frozen_string_literal: true

require "spec_helper"

# The live-tail watcher for an ATTACHED subagent: while the REPL is pinned to a
# running sub, each tick commits the sub's NEW transcript messages to scrollback
# (the append-only delta) and repaints a single transient "doing now" row, then
# stops with a final marker the moment the sub reaches a terminal state. These
# specs drive #tick directly (the ticker thread + timing are covered by the
# headless ttyd run); a stub composer stands in for the live one.
RSpec.describe Rubino::CLI::Chat::AttachedAgentWatcher do
  subject(:watcher) do
    described_class.new(host: host, id: "sa_1", ui: ui, rendered_count: rendered_count)
  end

  let(:ui) { Rubino::UI::Null.new }
  let(:session_resolver) { instance_double(Rubino::CLI::Chat::SessionResolver, replay_messages: nil) }
  let(:pastel) { Pastel.new(enabled: false) }

  # A stand-in host exposing the three private seams the watcher reaches into.
  let(:host) do
    instance_double(Rubino::CLI::ChatCommand).tap do |h|
      allow(h).to receive_messages(session_resolver: session_resolver, pastel: pastel)
      allow(h).to receive(:with_focused_view_replay) { |_c, &blk| blk.call }
    end
  end

  # A composer that records the transient-row frames it is handed.
  let(:composer) do
    Class.new do
      attr_reader :partials

      def initialize = @partials = []
      # Mirrors the real BottomComposer seam name, hence the writer prefix.
      def set_partial(str) = @partials << str # rubocop:disable Naming/AccessorMethodName
    end.new
  end

  let(:entry) do
    instance_double(Rubino::Tools::BackgroundTasks::Entry,
                    id: "sa_1", subagent: "explore", status: :running,
                    tool_count: 2, last_activity: "reading parser.rb",
                    output_tail: [], activity_log: activity_log, messages: messages)
  end
  let(:messages) { [] }
  let(:activity_log) { [] }
  let(:rendered_count) { 0 }

  before do
    allow(Rubino::Tools::BackgroundTasks.instance).to receive(:find).with("sa_1").and_return(entry)
  end

  def tick! = watcher.send(:tick, composer)

  describe "committed-message delta" do
    context "when entry.messages has grown past the rendered baseline" do
      let(:rendered_count) { 1 }
      let(:messages) { %w[m0 m1 m2 m3] } # 2 new past the baseline of 1

      it "replays ONLY the new tail (quiet, no 'Loaded N' banner) and advances the cursor" do
        expect(session_resolver).to receive(:replay_messages).with(ui, %w[m1 m2 m3], banner: false)
        tick!
        # A second tick with no further growth replays nothing more.
        expect(session_resolver).not_to receive(:replay_messages)
        tick!
      end
    end

    context "when entry.messages is unchanged since the last render" do
      let(:rendered_count) { 2 }
      let(:messages) { %w[m0 m1] }

      it "replays nothing new" do
        expect(session_resolver).not_to receive(:replay_messages)
        tick!
      end
    end
  end

  describe "live tail row" do
    it "paints a transient 'doing now' row from the sub's live fields" do
      tick!
      expect(composer.partials.last).to include("explore", "running", "2 tools", "reading parser.rb")
    end

    it "does NOT repaint the row when nothing changed across ticks" do
      tick!
      tick!
      expect(composer.partials.size).to eq(1)
    end

    context "when the sub has live intra-turn activity (long uncommitted turn)" do
      let(:activity_log) { ["✓ read · parser.rb", "✓ read · lexer.rb", "✓ glob · **/*.rb"] }

      it "surfaces the recent activity rows under the header so progress shows before the turn commits" do
        tick!
        frame = composer.partials.last
        expect(frame).to include("explore", "running", "2 tools")
        # The last MAX_LIVE_ROWS activity rows ride below the header as a block.
        expect(frame).to include("parser.rb", "lexer.rb", "**/*.rb")
        expect(frame.lines.size).to be > 1
      end

      it "repaints when the activity ring advances (new tool finished mid-turn)" do
        tick!
        first = composer.partials.last
        allow(entry).to receive(:activity_log)
          .and_return(["✓ read · lexer.rb", "✓ glob · **/*.rb", "✓ read · runner.rb"])
        tick!
        expect(composer.partials.last).not_to eq(first)
        expect(composer.partials.last).to include("runner.rb")
      end
    end
  end

  describe "terminal state while attached" do
    before { allow(entry).to receive(:status).and_return(:completed) }

    it "clears the live row and commits a single final marker" do
      tick!
      expect(composer.partials.last).to eq("") # transient row cleared
      marker = ui.messages.find { |m| m[:level] == :info && m[:message].include?("finished") }
      expect(marker[:message]).to include("sa_1", "completed", "/back")
    end

    it "commits the marker only once across repeated ticks" do
      tick!
      tick!
      markers = ui.messages.count { |m| m[:level] == :info && m[:message].include?("finished") }
      expect(markers).to eq(1)
    end

    it "reports not-live so the ticker loop will stop" do
      expect(watcher.send(:live?)).to be(false)
    end
  end

  describe "#live? gating the ticker loop" do
    it "is true while the sub still holds a live thread" do
      expect(watcher.send(:live?)).to be(true)
    end

    it "is false once the sub's entry is gone (reaped)" do
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:find).with("sa_1").and_return(nil)
      expect(watcher.send(:live?)).to be(false)
    end
  end

  # #82: the REPL rebuilds the composer every idle pass, so the watcher's focus
  # guard is the host's PERSISTENT @attached_id, NOT composer identity. A
  # composer-identity guard would falsely report "detached" the instant the
  # loop swapped composers and freeze the live tail.
  describe "#still_attached? (id-based, composer-identity-independent)" do
    before { host.instance_variable_set(:@attached_id, "sa_1") }

    it "is true while @attached_id matches, for ANY non-nil composer" do
      expect(watcher.send(:still_attached?, composer)).to be(true)
      # A DIFFERENT composer instance (the REPL rebuilt one) still counts as
      # attached — the guard is the id, not the instance.
      expect(watcher.send(:still_attached?, Object.new)).to be(true)
    end

    it "is false once @attached_id no longer matches (detached / switched)" do
      host.instance_variable_set(:@attached_id, nil)
      expect(watcher.send(:still_attached?, composer)).to be(false)
    end

    it "is false with no composer owning the screen (no TTY)" do
      expect(watcher.send(:still_attached?, nil)).to be(false)
    end
  end

  describe "live tail across a composer changeover (#82)" do
    it "REPAINTS the ⟂ frame on a fresh composer even when the status is unchanged" do
      tick! # paints onto the first composer
      expect(composer.partials.size).to eq(1)
      # The REPL rebuilt the composer (new idle pass); nothing about the sub
      # changed. The unchanged-frame cache must reset so the live tail lands on
      # the NEW screen instead of being skipped.
      fresh = composer.class.new
      watcher.send(:tick, fresh)
      expect(fresh.partials.last).to include("explore", "running")
    end
  end
end
