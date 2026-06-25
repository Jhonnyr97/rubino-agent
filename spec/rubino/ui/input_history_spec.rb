# frozen_string_literal: true

RSpec.describe Rubino::UI::InputHistory do
  # A private store so the spec never touches Reline::HISTORY global state, and
  # path: nil so the navigation/dedup unit specs stay purely in-memory (no disk).
  subject(:history) { described_class.new(store: store, path: nil) }

  let(:store) { [] }

  describe "#remember" do
    it "appends a submitted line" do
      history.remember("first")
      expect(store).to eq(["first"])
    end

    it "de-dups a CONSECUTIVE duplicate (like LineInput#remember)" do
      history.remember("same")
      history.remember("same")
      expect(store).to eq(["same"])
    end

    it "records a non-consecutive repeat" do
      history.remember("a")
      history.remember("b")
      history.remember("a")
      expect(store).to eq(%w[a b a])
    end

    it "ignores blank lines" do
      history.remember("   ")
      history.remember(nil)
      expect(store).to be_empty
    end

    it "strips before storing" do
      history.remember("  padded  ")
      expect(store).to eq(["padded"])
    end

    it "records slash commands too, so ↑ recalls them like bash/zsh/Claude Code (#2)" do
      history.remember("/new")
      history.remember("  /help  ")
      history.remember("a real prompt")
      expect(store).to eq(["/new", "/help", "a real prompt"])
    end

    it "a submitted /help is recalled by ↑ (#2)" do
      history.remember("/help")
      expect(history.up("draft")).to eq("/help")
    end
  end

  describe "disk persistence (#2 — survives a restart, mirrors Hermes .hermes_history)" do
    let(:dir)  { Dir.mktmpdir }
    let(:path) { File.join(dir, "history") }

    after { FileUtils.remove_entry(dir) if File.directory?(dir) }

    it "loads an existing history file into the ring at startup" do
      File.write(path, "older prompt\n/agents\nnewer prompt\n")
      ring = []
      described_class.new(store: ring, path: path)
      expect(ring).to eq(["older prompt", "/agents", "newer prompt"])
    end

    it "appends a submitted line to the file so it survives a restart" do
      h = described_class.new(store: [], path: path)
      h.remember("first prompt")
      h.remember("/help")
      expect(File.read(path)).to eq("first prompt\n/help\n")

      # A fresh process (new instance) recalls the persisted lines.
      reloaded = []
      described_class.new(store: reloaded, path: path)
      expect(reloaded).to eq(["first prompt", "/help"])
    end

    it "caps the on-disk file to the last N entries" do
      h = described_class.new(store: [], path: path, cap: 3)
      %w[a b c d e].each { |l| h.remember(l) }
      expect(File.read(path).split("\n")).to eq(%w[c d e])
    end

    it "loads only the last N entries when the file is over the cap" do
      File.write(path, (1..10).map { |i| "line#{i}" }.join("\n"))
      ring = []
      described_class.new(store: ring, path: path, cap: 2)
      expect(ring).to eq(%w[line9 line10])
    end

    it "a missing history file does not crash startup" do
      ring = []
      expect { described_class.new(store: ring, path: path) }.not_to raise_error
      expect(ring).to be_empty
    end

    it "an unwritable history path does not crash a turn" do
      h = described_class.new(store: [], path: File.join(dir, "nope", "history"))
      expect { h.remember("a prompt") }.not_to raise_error
      # The in-memory ring still works even though the append failed.
      expect(h.up("draft")).to eq("a prompt")
    end

    it "an unreadable/corrupt file does not crash startup (best-effort)" do
      File.write(path, "ok\n")
      allow(File).to receive(:foreach).and_raise(Errno::EACCES)
      ring = []
      expect { described_class.new(store: ring, path: path) }.not_to raise_error
    end
  end

  describe "navigation (↑ / ↓)" do
    before { %w[one two three].each { |l| history.remember(l) } }

    it "↑ walks back from newest to oldest" do
      expect(history.up("draft")).to eq("three")
      expect(history.up("draft")).to eq("two")
      expect(history.up("draft")).to eq("one")
    end

    it "↑ clamps at the oldest entry (returns nil to keep the buffer)" do
      3.times { history.up("draft") }
      expect(history.up("draft")).to be_nil
    end

    it "↓ walks forward and finally restores the stashed draft" do
      history.up("my draft") # stashes "my draft", shows "three"
      history.up("my draft") # "two"
      expect(history.down).to eq("three")
      expect(history.down).to eq("my draft") # back to the live draft
    end

    it "↓ is a no-op (nil) when not navigating history" do
      expect(history.down).to be_nil
    end

    it "remember resets navigation so a fresh ↑ starts from newest" do
      history.up("d")
      history.remember("four")
      expect(history.up("d2")).to eq("four")
    end

    it "↑ is a no-op (nil) on an empty store" do
      empty = described_class.new(store: [], path: nil)
      expect(empty.up("d")).to be_nil
    end
  end
end
