# frozen_string_literal: true

require "spec_helper"

# Doc-drift guard for docs/agents.md "Statuses": the table must document every
# glyph/status pair the live /agents surface can actually render (the
# Commands::Executor#agent_status_icon vocabulary). #155 found `⊘ stopped`
# missing — a reader cross-checking the table against reality hit an
# undocumented glyph.
RSpec.describe Rubino::Commands::Executor do
  describe "docs/agents.md statuses table" do
    # The full glyph/status vocabulary #agent_status_icon renders.
    let(:status_rows) do
      [
        ["●", "running"],
        ["◌", "stopping"],
        ["⊘", "stopped"],
        ["●", "needs_approval"],
        ["⛔", "blocked_on_human"],
        ["◷", "blocked_on_parent"],
        ["✗", "failed"],
        ["✓", "done"]
      ]
    end

    it "documents every status the /agents surface renders (#155)" do
      doc   = File.read(File.expand_path("../../docs/agents.md", __dir__))
      table = doc[/### Statuses.*?\n\n###/m] || doc[/### Statuses.*/m]

      missing = status_rows.reject do |glyph, status|
        table.match?(/^\| `#{Regexp.escape(glyph)}` \| `#{Regexp.escape(status)}` \|/)
      end
      expect(missing).to be_empty,
                         "docs/agents.md statuses table is missing: #{missing.inspect}"
    end
  end
end
