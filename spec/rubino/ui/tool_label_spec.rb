# frozen_string_literal: true

# The shared `name hint` tool-label vocabulary used by both the interactive
# card open-row (UI::CLI) and the one-shot stderr trace (UI::HeadlessTrace).
RSpec.describe Rubino::UI::ToolLabel do
  describe ".pick_hint" do
    it "prefers pattern > file_path > path > command" do
      expect(described_class.pick_hint({ command: "ls", file_path: "a.rb" }))
        .to eq([:file_path, "a.rb"])
      expect(described_class.pick_hint({ command: "ls" }))
        .to eq([:command, "ls"])
      expect(described_class.pick_hint({ pattern: "TODO", path: "x" }))
        .to eq([:pattern, "TODO"])
    end

    it "accepts string keys too" do
      expect(described_class.pick_hint({ "command" => "ls" })).to eq([:command, "ls"])
    end

    it "names the web tools by their url / query so the card isn't bare" do
      expect(described_class.pick_hint({ url: "https://example.com/doc" }))
        .to eq([:url, "https://example.com/doc"])
      expect(described_class.pick_hint({ query: "ruby streaming" }))
        .to eq([:query, "ruby streaming"])
    end

    it "returns nil when no identifying key carries a value" do
      expect(described_class.pick_hint({})).to be_nil
      expect(described_class.pick_hint({ file_path: "" })).to be_nil
      expect(described_class.pick_hint(nil)).to be_nil
    end
  end

  describe ".label" do
    it "builds `name hint`" do
      expect(described_class.label("edit", { file_path: "foo.rb" })).to eq("edit foo.rb")
      expect(described_class.label("bash", { command: "npm test" })).to eq("bash npm test")
    end

    it "falls back to the bare name with no identifying arg" do
      expect(described_class.label("todo", {})).to eq("todo")
    end

    it "truncates a long hint with an ellipsis (default cap)" do
      long = "x" * 200
      out = described_class.label("read", { file_path: long })
      expect(out.length).to be < 70
      expect(out).to end_with("...")
    end

    it "widens the cap under verbose" do
      long = "x" * 200
      out = described_class.label("read", { file_path: long }, verbose: true)
      expect(out.length).to be > 70
    end
  end
end
