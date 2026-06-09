# frozen_string_literal: true

RSpec.describe Rubino::UI::InputHistory do
  # A private store so the spec never touches Reline::HISTORY global state.
  subject(:history) { described_class.new(store: store) }

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

    it "does not record slash commands (H1: ↑ surfaces prompts, not commands)" do
      history.remember("/new")
      history.remember("  /help  ")
      history.remember("a real prompt")
      expect(store).to eq(["a real prompt"])
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

    it "#navigating? is true only while walking the ring" do
      expect(history.navigating?).to be(false)
      history.up("d")
      expect(history.navigating?).to be(true)
      history.down # back to draft
      expect(history.navigating?).to be(false)
    end

    it "remember resets navigation so a fresh ↑ starts from newest" do
      history.up("d")
      history.remember("four")
      expect(history.up("d2")).to eq("four")
    end

    it "↑ is a no-op (nil) on an empty store" do
      empty = described_class.new(store: [])
      expect(empty.up("d")).to be_nil
    end
  end
end
