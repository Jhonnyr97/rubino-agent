# frozen_string_literal: true

RSpec.describe Rubino::Util::Duration do
  describe ".human_duration" do
    it "renders sub-minute spans in seconds" do
      expect(described_class.human_duration(0)).to eq("0s")
      expect(described_class.human_duration(45)).to eq("45s")
      expect(described_class.human_duration(59)).to eq("59s")
    end

    it "renders whole minutes from 60s up to an hour" do
      expect(described_class.human_duration(60)).to eq("1m")
      expect(described_class.human_duration(150)).to eq("2m")
      expect(described_class.human_duration(3599)).to eq("59m")
    end

    it "renders whole hours from an hour up" do
      expect(described_class.human_duration(3600)).to eq("1h")
      expect(described_class.human_duration(7300)).to eq("2h")
    end

    it "truncates fractional seconds toward zero" do
      expect(described_class.human_duration(38.9)).to eq("38s")
    end
  end
end
