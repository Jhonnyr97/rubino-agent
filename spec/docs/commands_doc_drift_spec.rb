# frozen_string_literal: true

require "spec_helper"

# Doc-drift guard: docs/commands.md claims its slash-command table mirrors
# BuiltIns::DESCRIPTIONS (the same source /help and tab-completion read). This
# spec makes the claim honest — adding/renaming/removing a built-in command
# fails the suite until the doc table is regenerated to match.
RSpec.describe Rubino::Commands::BuiltIns do
  describe "docs/commands.md slash-command table" do
    it "matches BuiltIns::DESCRIPTIONS exactly (names, descriptions, order)" do
      doc = File.read(File.expand_path("../../docs/commands.md", __dir__))

      # Table rows of the form: | `/name` | description |  (descriptions may
      # contain markdown-escaped pipes "\|", which map back to "|").
      rows = doc.scan(%r{^\| `(/[\w-]+)` \| (.+) \|$}).map do |name, desc|
        [name, desc.gsub("\\|", "|").strip]
      end

      expect(rows).to eq(described_class::DESCRIPTIONS.to_a)
    end
  end
end
