# frozen_string_literal: true

# Session::Picker is the ONE arrow-key chooser shared by both resume surfaces
# (#40). Its row-label formatting (class methods, so the in-REPL `/sessions`
# chooser and the CLI picker render identically) is pinned here.
RSpec.describe Rubino::Session::Picker do
  describe ".session_title" do
    it "returns (untitled) for a blank title" do
      expect(described_class.session_title({ title: "" })).to eq("(untitled)")
    end

    it "passes a normal-length title through unchanged" do
      expect(described_class.session_title({ title: "ship the release" })).to eq("ship the release")
    end

    # #581 — a long renamed (or pre-fix) title must be length-capped on the
    # picker row, else it soft-wraps the chooser across the whole screen and
    # pushes every subsequent row out of view. Belt-and-suspenders alongside
    # the rename write cap.
    it "truncates a 2000-char title to TITLE_MAX_CHARS with an ellipsis" do
      cap = Rubino::Session::Repository::TITLE_MAX_CHARS

      title = described_class.session_title({ title: "L" * 2000 })

      expect(title.length).to be <= cap + 1 # cap chars + the "…" ellipsis
      expect(title).to end_with("…")
      expect(title).to start_with("L" * cap)
    end
  end

  describe ".session_choice_label" do
    it "keeps the whole row bounded when the title is enormous (#581)" do
      cap = Rubino::Session::Repository::TITLE_MAX_CHARS

      label = described_class.session_choice_label(
        { id: "abc12345deadbeef", title: "L" * 2000, message_count: 2 }
      )

      # The id (8) + spacing + a cap-bounded title + meta — nowhere near 2000.
      expect(label.length).to be < cap + 80
      expect(label).to include("abc12345")
    end
  end
end
