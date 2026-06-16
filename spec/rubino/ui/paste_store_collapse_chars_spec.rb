# frozen_string_literal: true

# Paste chip consistency: the "[Pasted text #N]" chip (#437) must trigger for
# ANY large paste, not only multi-line ones. A big SINGLE-LINE paste (a long
# URL / token / minified JSON) has too few newlines for the line-count rule, so
# it used to flood the composer. collapse? now also fires on character count.
RSpec.describe Rubino::UI::PasteStore do
  subject(:store) { described_class.new(config: test_configuration) }

  describe "#collapse?" do
    it "collapses a big SINGLE-LINE paste (char threshold)" do
      big_one_line = "x" * (described_class::DEFAULT_COLLAPSE_CHARS + 50)
      expect(big_one_line.lines.length).to eq(1)
      expect(store.collapse?(big_one_line)).to be(true)
    end

    it "still collapses a multi-line paste (line threshold)" do
      multi = "a\n" * (described_class::DEFAULT_COLLAPSE_LINES + 2)
      expect(store.collapse?(multi)).to be(true)
    end

    it "does NOT collapse a short single-line paste" do
      expect(store.collapse?("a short line")).to be(false)
    end

    it "registers a big single-line paste to a chip token" do
      token = store.register("y" * (described_class::DEFAULT_COLLAPSE_CHARS + 100))
      expect(token).to match(/\A\[Pasted text #\d+ \+\d+ lines\]\z/)
    end
  end
end
