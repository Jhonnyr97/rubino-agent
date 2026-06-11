# frozen_string_literal: true

require "spec_helper"

# Doc-drift guard: docs/tools.md states the built-in tool count, the full
# tool list, and the number of config groups `rubino tools` shows. This spec
# checks all three against the live registry, so the doc cannot drift the way
# the old hardcoded counts did (29 vs 23 vs 26 — issue #113).
RSpec.describe Rubino::Tools::Registry do
  describe "docs/tools.md built-in tool inventory" do
    before { described_class.register_defaults! }

    let(:doc) { File.read(File.expand_path("../../docs/tools.md", __dir__)) }

    it "states the registry's tool count" do
      stated = doc[/rubino ships \*\*(\d+) built-in tools\*\*/, 1]
      expect(stated).not_to be_nil, "tools.md no longer states the tool count"
      expect(Integer(stated)).to eq(described_class.all.size)
    end

    it "lists every registered tool, in registration order" do
      list_line = doc[/^The full list \(registration order\): (.+)$/, 1]
      expect(list_line).not_to be_nil, "tools.md no longer carries the full list"

      documented = list_line.scan(/`([a-z_]+)`/).flatten
      expect(documented).to eq(described_class.all.map(&:name))
    end

    it "states the number of config groups `rubino tools` shows" do
      stated = doc[/shows \*\*(\d+) rows\*\*/, 1]
      expect(stated).not_to be_nil, "tools.md no longer states the config-group count"

      groups = described_class.all.map(&:config_key).uniq
      expect(Integer(stated)).to eq(groups.size)
    end

    it "documents each registered tool with its own section heading" do
      headings = doc.scan(/^### ([a-z_]+)$/).flatten
      expect(described_class.all.map(&:name) - headings).to be_empty
    end
  end
end
