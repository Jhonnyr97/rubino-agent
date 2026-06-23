# frozen_string_literal: true

RSpec.describe Rubino::Util::Duration do
  describe ".human_duration" do
    it "renders sub-minute spans in seconds" do
      expect(described_class.human_duration(0)).to eq("0s")
      expect(described_class.human_duration(45)).to eq("45s")
      expect(described_class.human_duration(59)).to eq("59s")
    end

    it "renders whole minutes from 60s up to an hour (coarse default, for ages)" do
      expect(described_class.human_duration(60)).to eq("1m")
      expect(described_class.human_duration(150)).to eq("2m")
      expect(described_class.human_duration(3599)).to eq("59m")
    end

    it "renders whole hours from an hour up (coarse default)" do
      expect(described_class.human_duration(3600)).to eq("1h")
      expect(described_class.human_duration(7300)).to eq("2h")
    end

    it "truncates fractional seconds toward zero" do
      expect(described_class.human_duration(38.9)).to eq("38s")
    end

    # #44 — a live counter passes precise: true so it carries the next-smaller
    # unit and visibly advances every second instead of sitting on a whole
    # minute for ~59s and reading as frozen. Ages keep the coarse default above.
    it "carries trailing seconds/minutes when precise (for a live counter)" do
      expect(described_class.human_duration(45, precise: true)).to eq("45s")
      expect(described_class.human_duration(60, precise: true)).to eq("1m00s")
      expect(described_class.human_duration(65, precise: true)).to eq("1m05s")
      expect(described_class.human_duration(150, precise: true)).to eq("2m30s")
      expect(described_class.human_duration(3599, precise: true)).to eq("59m59s")
      expect(described_class.human_duration(3600, precise: true)).to eq("1h00m")
      expect(described_class.human_duration(7300, precise: true)).to eq("2h01m")
    end
  end
end
