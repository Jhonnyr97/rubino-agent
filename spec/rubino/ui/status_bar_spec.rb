# frozen_string_literal: true

RSpec.describe Rubino::UI::StatusBar do
  # A color-forced pastel so the threshold assertions see real SGR codes
  # regardless of the test process's TTY.
  let(:pastel) { Pastel.new(enabled: true) }
  # And a disabled one for the plain-text shape assertions.
  let(:plain) { Pastel.new(enabled: false) }

  describe ".render" do
    # P9: ONE encoding of the saturation — used/window with the % alongside.
    # Rail rubino: a single leading space tucks the bar under the input rail.
    it "formats model · ctx ~used/window (%)" do
      line = described_class.render(model: "minimax-m3", tokens: 8_421, window: 64_000, pastel: plain)
      expect(line).to eq(" minimax-m3 · ctx ~8.4k/64k (13%)")
    end

    # TUI-1: a sub-1k session must render the USED figure in the same `k` unit
    # as the window AND always show the percentage, so `~129/128k` can never
    # scan as "over budget". A near-empty session reads `~0.1k/128k (0%)`.
    it "renders the used figure in the window's k unit below 1k (never over-budget)" do
      line = described_class.render(model: "minimax-m3", tokens: 105, window: 128_000, pastel: plain)
      expect(line).to eq(" minimax-m3 · ctx ~0.1k/128k (0%)")
    end

    it "always shows the percentage when the window is known" do
      line = described_class.render(model: "m3", tokens: 105, window: 128_000, pastel: plain)
      expect(line).to include("(0%)")
    end

    it "drops the percentage when the window is unknown (nil)" do
      line = described_class.render(model: "m", tokens: 8_421, window: nil, pastel: plain)
      expect(line).to eq(" m · ~8.4k tok")
    end

    it "treats a zero window as unknown too" do
      line = described_class.render(model: "m", tokens: 10, window: 0, pastel: plain)
      expect(line).to eq(" m · ~10 tok")
    end

    # Rail rubino: the prompt chip moved here — the MODE token leads, then
    # the optional skill token, then model + ctx.
    describe "session chips" do
      it "leads with the mode token" do
        line = described_class.render(model: "minimax-m3", tokens: 4_400, window: 128_000,
                                      chips: { mode: :default }, pastel: plain)
        expect(line).to eq(" default · minimax-m3 · ctx ~4.4k/128k (3%)")
      end

      it "renders mode · skill <name> · model with an active skill" do
        line = described_class.render(model: "m3", tokens: 100, window: nil,
                                      chips: { mode: :default, skill: "ruby-expert" }, pastel: plain)
        expect(line).to eq(" default · skill ruby-expert · m3 · ~100 tok")
      end

      # #320: the active primary agent chip sits right after the mode.
      it "renders the agent token after the mode" do
        line = described_class.render(model: "m3", tokens: 100, window: nil,
                                      chips: { mode: :default, agent: "plan" }, pastel: plain)
        expect(line).to eq(" default · agent plan · m3 · ~100 tok")
      end

      it "omits every chip when none is given (legacy bare bar)" do
        line = described_class.render(model: "m3", tokens: 100, window: nil, pastel: plain)
        expect(line).to eq(" m3 · ~100 tok")
      end

      it "accents the mode subtly: default dim, plan yellow, yolo red" do
        dim    = described_class.render(model: "m", tokens: 1, chips: { mode: :default }, pastel: pastel)
        plan   = described_class.render(model: "m", tokens: 1, chips: { mode: :plan }, pastel: pastel)
        yolo   = described_class.render(model: "m", tokens: 1, chips: { mode: :yolo }, pastel: pastel)
        expect(dim).to start_with(" \e[2mdefault\e[0m")
        expect(plan).to start_with(" \e[33mplan\e[0m")   # yellow, no bold
        expect(yolo).to start_with(" \e[31myolo\e[0m")   # the rail's red accent
      end
    end

    it "renders dim below the warn threshold (no yellow/red)" do
      line = described_class.render(model: "m", tokens: 10_000, window: 100_000, pastel: pastel)
      expect(line).to include("\e[2m")        # dim segments
      expect(line).not_to include("\e[33m")   # no yellow
      expect(line).not_to include("\e[31m")   # no red
    end

    it "colors the percentage yellow from 70%" do
      line = described_class.render(model: "m", tokens: 70_000, window: 100_000, pastel: pastel)
      expect(line).to include("\e[33m70%")
    end

    it "colors the percentage red from 90%" do
      line = described_class.render(model: "m", tokens: 95_000, window: 100_000, pastel: pastel)
      expect(line).to include("\e[31m95%")
    end

    it "styles each segment separately so a colored % can't strip the dim" do
      line = described_class.render(model: "m", tokens: 95_000, window: 100_000, pastel: pastel)
      # The token-count segment AFTER the red % still opens its own dim span.
      expect(line.split("95%").last).to include("\e[2m")
    end

    # TUI-5: the percentage is a SATURATION gauge — it must never read past
    # 100% even when the provider-reported prompt size (tokens) exceeds the
    # window (a pinned context.max_tokens smaller than the real prompt, or the
    # provider counting more than the chars/4 default assumes). An unclamped
    # ratio printed an impossible "(245%)" / "(230%)".
    it "clamps the percentage at 100% when tokens exceed the window" do
      line = described_class.render(model: "m3", tokens: 26_600, window: 8_000, pastel: plain)
      expect(line).to eq(" m3 · ctx ~26.6k/8k (100%)")
    end

    it "still shows the raw tokens/window pair when over budget" do
      # The over-budget state stays visible (26.6k > 8k) — only the % is pinned.
      line = described_class.render(model: "m3", tokens: 26_600, window: 8_000, pastel: plain)
      expect(line).to include("~26.6k/8k")
    end

    it "colors a clamped over-budget percentage red (crit band)" do
      line = described_class.render(model: "m", tokens: 46, window: 20, pastel: pastel)
      expect(line).to include("\e[31m100%")
    end

    # TUI-1: the reported "ctx ~245/128k" was the over-budget-LOOKING bug —
    # 245 tokens IS 0.2% of a 128k window, but the bare `245` next to `128k`
    # scanned as full. The fix renders the used figure in the window's `k` unit
    # and always shows the (clamped) percentage, so the tiny ratio reads
    # unambiguously as `~0.2k/128k (0%)`.
    it "renders a tiny legitimate ratio in matched units with a 0% gauge" do
      line = described_class.render(model: "m3", tokens: 245, window: 128_000, pastel: plain)
      expect(line).to eq(" m3 · ctx ~0.2k/128k (0%)")
    end
  end

  describe ".abbreviate_to" do
    it "forces the used figure into k when the window is in k" do
      expect(described_class.abbreviate_to(129, 128_000)).to eq("0.1k")
      expect(described_class.abbreviate_to(8_421, 64_000)).to eq("8.4k")
    end

    it "floors a non-zero sub-100 count to 0.1k (never a misleading 0k)" do
      expect(described_class.abbreviate_to(5, 128_000)).to eq("0.1k")
    end

    it "renders a zero count as 0k" do
      expect(described_class.abbreviate_to(0, 128_000)).to eq("0k")
    end

    it "falls back to the plain abbreviation for a sub-1k window (units already match)" do
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
      expect(described_class.abbreviate(64_000)).to eq("64k") # trailing .0 trimmed
    end

    it "rounds whole above 100k" do
      expect(described_class.abbreviate(128_000)).to eq("128k")
      expect(described_class.abbreviate(200_500)).to eq("201k")
    end
  end
end
