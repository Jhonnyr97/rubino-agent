# frozen_string_literal: true

RSpec.describe Rubino::UI::StatusBar do
  let(:pastel) { Pastel.new(enabled: true) }
  let(:plain)  { Pastel.new(enabled: false) }

  describe ".render — 3 width tiers" do
    # ── tier: 76+ cols ──────────────────────────────────────────────
    it "shows full bar at 76+ cols: provider/model · ctx ~used/window (pct%) · Nk cached" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 8_421, window: 64_000, cached: 12_000, cols: 80, pastel: plain
      )
      expect(line).to eq(" openrouter/gpt-4.1 · ctx ~8.4k/64k (13%) · 12k cached")
    end

    it "omits cached when 0 at full width" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 8_421, window: 64_000, cached: 0, cols: 80, pastel: plain
      )
      expect(line).to eq(" openrouter/gpt-4.1 · ctx ~8.4k/64k (13%)")
    end

    it "omits cached when nil" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 8_421, window: 64_000, cached: nil, cols: 80, pastel: plain
      )
      expect(line).not_to include("cached")
    end

    # ── tier: 52-75 cols ────────────────────────────────────────────
    it "shows medium bar at 52-75 cols: provider/model · ~used/window (pct%)" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 8_421, window: 64_000, cached: 12_000, cols: 60, pastel: plain
      )
      expect(line).to eq(" openrouter/gpt-4.1 · ~8.4k/64k (13%)")
    end

    it "omits cached and ctx prefix at medium width" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 8_421, window: 64_000, cached: 12_000, cols: 52, pastel: plain
      )
      expect(line).to eq(" openrouter/gpt-4.1 · ~8.4k/64k (13%)")
    end

    # ── tier: <52 cols ──────────────────────────────────────────────
    it "shows narrow bar at <52 cols: model · pct%" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 8_421, window: 64_000, cols: 40, pastel: plain
      )
      expect(line).to eq(" gpt-4.1 · 13%")
    end

    it "drops provider first at narrow width" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 8_421, window: 64_000, cols: 40, pastel: plain
      )
      expect(line).to start_with(" gpt-4.1")
      expect(line).not_to include("openrouter")
    end

    it "drops percentage when window is unknown even at narrow width" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 8_421, window: nil, cols: 40, pastel: plain
      )
      expect(line).to eq(" gpt-4.1")
    end
  end

  describe ".render — provider/model glue" do
    it "glues provider and model with /" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 100, window: 64_000, cached: 0, cols: 80, pastel: plain
      )
      expect(line).to include("openrouter/gpt-4.1")
    end

    it "collapses to bare model when provider is nil" do
      line = described_class.render(
        provider: nil, model: "gpt-4.1",
        tokens: 100, window: 64_000, cached: 0, cols: 80, pastel: plain
      )
      expect(line).to include("gpt-4.1")
      expect(line).not_to include("/gpt-4.1")
    end

    it "collapses to bare model when provider equals model" do
      line = described_class.render(
        provider: "claude", model: "claude",
        tokens: 100, window: 64_000, cached: 0, cols: 80, pastel: plain
      )
      expect(line).to include("claude")
      expect(line).not_to include("claude/claude")
    end

    it "dims the / separator" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 100, window: 64_000, cached: 0, cols: 80, pastel: pastel
      )
      # The whole provider/model segment is dim — no standalone / check needed.
      expect(line).to include("\e[2mopenrouter/gpt-4.1\e[0m")
    end
  end

  describe ".render — mode prefix" do
    it "omits mode entirely when nil" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 100, window: 64_000, cached: 0, cols: 80, mode: nil, pastel: plain
      )
      expect(line).to start_with(" openrouter/gpt-4.1")
    end

    it "omits mode when :default" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 100, window: 64_000, cached: 0, cols: 80, mode: :default, pastel: plain
      )
      expect(line).to start_with(" openrouter/gpt-4.1")
    end

    it "omits mode for 'default' string too" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 100, window: 64_000, cached: 0, cols: 80, mode: "default", pastel: plain
      )
      expect(line).to start_with(" openrouter/gpt-4.1")
    end

    it "accent plan in yellow" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 100, window: 64_000, cached: 0, cols: 80, mode: :plan, pastel: pastel
      )
      expect(line).to start_with(" \e[33mplan\e[0m")
    end

    it "accent yolo in red" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 100, window: 64_000, cached: 0, cols: 80, mode: :yolo, pastel: pastel
      )
      expect(line).to start_with(" \e[31myolo\e[0m")
    end
  end

  describe ".render — percentage thresholds" do
    it "renders dim below the warn threshold" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 10_000, window: 100_000, cols: 80, pastel: pastel
      )
      expect(line).to include("\e[2m10%")
    end

    it "colors the percentage yellow from 70%" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 70_000, window: 100_000, cols: 80, pastel: pastel
      )
      expect(line).to include("\e[33m70%")
    end

    it "colors the percentage red from 90%" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 95_000, window: 100_000, cols: 80, pastel: pastel
      )
      expect(line).to include("\e[31m95%")
    end

    it "styles each segment separately so a colored % can't strip the dim" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 95_000, window: 100_000, cols: 80, pastel: pastel
      )
      expect(line.split("95%").last).to include("\e[2m")
    end

    it "clamps the percentage at 100% when tokens exceed the window" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 26_600, window: 8_000, cols: 80, pastel: plain
      )
      expect(line).to eq(" openrouter/gpt-4.1 · ctx ~26.6k/8k (100%)")
    end

    it "still shows the raw tokens/window pair when over budget" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 26_600, window: 8_000, cols: 80, pastel: plain
      )
      expect(line).to include("~26.6k/8k")
    end

    it "colors a clamped over-budget percentage red" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 46, window: 20, cols: 80, pastel: pastel
      )
      expect(line).to include("\e[31m100%")
    end

    # TUI-1 invariant: a tiny ratio must read unambiguously
    it "renders a tiny legitimate ratio in matched units with a 0% gauge" do
      line = described_class.render(
        provider: "openrouter", model: "gpt-4.1",
        tokens: 245, window: 128_000, cols: 80, pastel: plain
      )
      expect(line).to eq(" openrouter/gpt-4.1 · ctx ~0.2k/128k (0%)")
    end
  end

  describe ".render — no agent chip" do
    it "does not accept an agent argument" do
      expect { described_class.render(agent: "plan", model: "m", tokens: 1, pastel: plain) }
        .to raise_error(ArgumentError, /unknown keyword: :?agent/)
    end

    it "does not accept a chips argument" do
      expect { described_class.render(chips: {}, model: "m", tokens: 1, pastel: plain) }
        .to raise_error(ArgumentError, /unknown keyword: :?chips/)
    end
  end

  describe ".abbreviate_to" do
    it "forces the used figure into k when the window is in k" do
      expect(described_class.abbreviate_to(129, 128_000)).to eq("0.1k")
      expect(described_class.abbreviate_to(8_421, 64_000)).to eq("8.4k")
    end

    it "floors a non-zero sub-100 count to 0.1k" do
      expect(described_class.abbreviate_to(5, 128_000)).to eq("0.1k")
    end

    it "renders a zero count as 0k" do
      expect(described_class.abbreviate_to(0, 128_000)).to eq("0k")
    end

    it "falls back to the plain abbreviation for a sub-1k window" do
      expect(described_class.abbreviate_to(50, 500)).to eq("50")
    end
  end

  describe ".context_pct" do
    it "clamps to 0..100" do
      expect(described_class.context_pct(46, 20)).to eq(100)
      expect(described_class.context_pct(13, 100)).to eq(13)
      expect(described_class.context_pct(0, 100)).to eq(0)
    end

    it "is 0 for a non-positive window" do
      expect(described_class.context_pct(50, 0)).to eq(0)
      expect(described_class.context_pct(50, nil)).to eq(0)
    end
  end

  describe ".abbreviate" do
    it "keeps counts under 1000 verbatim" do
      expect(described_class.abbreviate(842)).to eq("842")
      expect(described_class.abbreviate(0)).to eq("0")
    end

    it "renders one decimal under 100k" do
      expect(described_class.abbreviate(8_421)).to eq("8.4k")
      expect(described_class.abbreviate(64_000)).to eq("64k")
    end

    it "rounds whole above 100k" do
      expect(described_class.abbreviate(128_000)).to eq("128k")
      expect(described_class.abbreviate(200_500)).to eq("201k")
    end
  end
end
