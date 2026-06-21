# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::UI::MenuView do
  # Strip SGR so assertions read the glyphs/text, not the colour escapes
  # (pastel is a no-op off a TTY in CI anyway, but be explicit).
  def plain(rows) = rows.map { |r| r.gsub(/\e\[[0-9;]*m/, "") }

  def labels(count) = (1..count).map { |i| { label: "item#{i}" } }

  describe ".render" do
    it "returns [] for an empty row set" do
      expect(described_class.render([], 80, window: { selected: 0, top: 0, max_rows: 8 })).to eq([])
    end

    it "marks the selected row with ❯ + inverse padding and the rest with a dim ┊" do
      out = plain(described_class.render(labels(3), 80, window: { selected: 1, top: 0, max_rows: 8 }))
      expect(out).to eq(["┊ item1", "❯  item2 ", "┊ item3"])
    end

    it "renders a `┄ header ┄` row first when a header is given" do
      out = plain(described_class.render(labels(2), 80, window: { selected: 0, top: 0, max_rows: 8 },
                                                        header: "subagents"))
      expect(out.first).to eq("┄ subagents ┄")
      expect(out).to include("❯  item1 ")
    end

    it "omits the header row when none is given" do
      out = plain(described_class.render(labels(2), 80, window: { selected: 0, top: 0, max_rows: 8 }))
      expect(out.none? { |r| r.start_with?("┄ ") && r.end_with?(" ┄") && !r.include?("/") }).to be(true)
    end

    describe "footer" do
      it "is shown only when the list overflows the window, as `┄ n/total · hints ┄`" do
        out = plain(described_class.render(labels(10), 80, window: { selected: 0, top: 0, max_rows: 8 },
                                                           hints: "Enter · Esc"))
        expect(out.last).to eq("┄ 1/10 · Enter · Esc ┄")
      end

      it "is omitted when the whole list fits the window" do
        out = plain(described_class.render(labels(3), 80, window: { selected: 0, top: 0, max_rows: 8 }, hints: "Enter"))
        expect(out.any? { |r| r.include?("/") }).to be(false)
      end

      it "shows the count alone when no hints are given" do
        out = plain(described_class.render(labels(10), 80, window: { selected: 4, top: 0, max_rows: 8 }))
        expect(out.last).to eq("┄ 5/10 ┄")
      end

      it "reports the GLOBAL selected index, not the windowed one" do
        out = plain(described_class.render(labels(20), 80, window: { selected: 12, top: 8, max_rows: 8 }, hints: "x"))
        expect(out.last).to eq("┄ 13/20 · x ┄")
      end
    end

    describe "scroll window" do
      it "shows only the +max_rows+ slice starting at +top+" do
        out = plain(described_class.render(labels(20), 80, window: { selected: 10, top: 8, max_rows: 5 }))
        body = out.reject { |r| r.include?("/") } # drop footer
        expect(body.map { |r| r.sub(/^[❯┊]\s+/, "").strip }).to eq(%w[item9 item10 item11 item12 item13])
      end
    end

    describe "description column" do
      it "appends a dim aligned description and pads unselected rows by +2 to match the inverse width" do
        rows = [{ label: "a", desc: "alpha" }, { label: "bb", desc: "beta" }]
        out = plain(described_class.render(rows, 80, window: { selected: 0, top: 0, max_rows: 8 }))
        # selected "a" widened by the inverse spaces; unselected "bb" padded +2
        expect(out[0]).to eq("❯  a  alpha")
        expect(out[1]).to eq("┊ bb  beta")
      end
    end

    describe "sub-line" do
      it "draws a dim sub-line under the SELECTED row only" do
        rows = [{ label: "one", sub: "doing stuff" }, { label: "two", sub: "other" }]
        out = plain(described_class.render(rows, 80, window: { selected: 0, top: 0, max_rows: 8 }))
        expect(out).to eq(["❯  one ", "  doing stuff", "┊ two"])
      end

      it "ignores a blank sub-line" do
        rows = [{ label: "one", sub: "" }]
        out = plain(described_class.render(rows, 80, window: { selected: 0, top: 0, max_rows: 8 }))
        expect(out).to eq(["❯  one "])
      end
    end

    it "clamps each row to the available columns" do
      out = described_class.render([{ label: "x" * 200 }], 10, window: { selected: 0, top: 0, max_rows: 8 })
      expect(Rubino::UI::LiveRegion.display_width(out.first)).to be <= 10
    end
  end

  describe ".window_top" do
    it "is 0 when the list fits the window" do
      expect(described_class.window_top(3, 4, 0, 5)).to eq(0)
    end

    it "scrolls down to keep a selection below the window in view" do
      expect(described_class.window_top(7, 20, 0, 5)).to eq(3)
    end

    it "scrolls up to keep a selection above the window in view" do
      expect(described_class.window_top(2, 20, 8, 5)).to eq(2)
    end

    it "leaves the window put when the selection is already inside it" do
      expect(described_class.window_top(9, 20, 8, 5)).to eq(8)
    end

    it "never scrolls past the end" do
      expect(described_class.window_top(19, 20, 0, 5)).to eq(15)
    end
  end
end
