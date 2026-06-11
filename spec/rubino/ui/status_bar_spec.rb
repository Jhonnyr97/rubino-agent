# frozen_string_literal: true

RSpec.describe Rubino::UI::StatusBar do
  # A color-forced pastel so the threshold assertions see real SGR codes
  # regardless of the test process's TTY.
  let(:pastel) { Pastel.new(enabled: true) }
  # And a disabled one for the plain-text shape assertions.
  let(:plain) { Pastel.new(enabled: false) }

  describe ".render" do
    # P9: ONE encoding of the saturation — used/window with the % alongside.
    it "formats model · ctx ~used/window (%)" do
      line = described_class.render(model: "minimax-m3", tokens: 8_421, window: 64_000, pastel: plain)
      expect(line).to eq("  minimax-m3 · ctx ~8.4k/64k (13%)")
    end

    # P9: a fresh session must not carry a permanent "(0%)".
    it "drops the percentage entirely below 1%" do
      line = described_class.render(model: "minimax-m3", tokens: 105, window: 128_000, pastel: plain)
      expect(line).to eq("  minimax-m3 · ctx ~105/128k")
    end

    it "drops the percentage when the window is unknown (nil)" do
      line = described_class.render(model: "m", tokens: 8_421, window: nil, pastel: plain)
      expect(line).to eq("  m · ~8.4k tok")
    end

    it "treats a zero window as unknown too" do
      line = described_class.render(model: "m", tokens: 10, window: 0, pastel: plain)
      expect(line).to eq("  m · ~10 tok")
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
