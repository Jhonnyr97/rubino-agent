# frozen_string_literal: true

RSpec.describe Rubino::Util::Output do
  describe ".preview" do
    it "returns empty string when input is nil or empty" do
      expect(described_class.preview(nil)).to eq("")
      expect(described_class.preview("")).to eq("")
    end

    it "returns the full text unchanged when line count is at or below the cap" do
      text = (1..30).map { |i| "line #{i}" }.join("\n")
      expect(described_class.preview(text)).to eq(text)
    end

    it "trims to head + marker + tail when above the cap" do
      text = (1..50).map { |i| "line #{i}" }.join("\n")
      result = described_class.preview(text)

      head = (1..5).map { |i| "line #{i}" }
      tail = (41..50).map { |i| "line #{i}" }
      expect(result).to eq((head + ["… [35 more lines · full in DB] …"] + tail).join("\n"))
    end

    it "reports the exact number of omitted lines in the marker" do
      text = (1..100).map { |i| "x#{i}" }.join("\n")
      expect(described_class.preview(text)).to include("[85 more lines · full in DB]")
    end

    it "honours custom head, tail, and max" do
      text = (1..20).map { |i| "L#{i}" }.join("\n")
      result = described_class.preview(text, max: 10, head: 2, tail: 3)
      expect(result.lines.map(&:chomp)).to eq([
                                                "L1", "L2",
                                                "… [15 more lines · full in DB] …",
                                                "L18", "L19", "L20"
                                              ])
    end

    it "leaves single-line input alone" do
      expect(described_class.preview("just one line")).to eq("just one line")
    end

    it "is a pure function — does not mutate the input" do
      text = (1..40).map { |i| "row #{i}\n" }.join
      frozen = text.dup.freeze
      expect { described_class.preview(frozen) }.not_to raise_error
    end
  end

  describe ".elide" do
    it "returns the text unchanged when within the budget" do
      expect(described_class.elide("hello", 80)).to eq("hello")
    end

    it "returns the text unchanged when exactly at the budget" do
      expect(described_class.elide("abcde", 5)).to eq("abcde")
    end

    it "cuts to max chars and appends an ellipsis when over budget" do
      expect(described_class.elide("abcdef", 3)).to eq("abc…")
    end

    it "coerces non-string input via #to_s" do
      expect(described_class.elide(12_345, 3)).to eq("123…")
      expect(described_class.elide(nil, 10)).to eq("")
    end
  end
end
