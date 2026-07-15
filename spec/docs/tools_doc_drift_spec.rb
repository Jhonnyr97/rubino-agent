# frozen_string_literal: true

require "spec_helper"

# Doc-drift guard: docs/tools.md states the built-in tool count, the full
# tool list, and the number of config groups `rubino tools` shows. This spec
# checks all three against the live registry, so the doc cannot drift the way
# the old hardcoded counts did (29 vs 23 vs 26 — issue #113).
RSpec.describe Rubino::Tools::Registry do
  describe "docs/tools.md built-in tool inventory" do
    # Rebuild a CLEAN registry so the assertion sees the canonical build order
    # (register_defaults!'s explicit list), not whatever ambient/mutated state a
    # prior example left behind — the tool order must be deterministic.
    before { described_class.reset!; described_class.register_defaults! }

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

  # retrieve_output is the ONLY recovery path for compressed tool output, and is
  # registered SOLELY when tool_output_compression is enabled — so the default
  # (off) registry/count documented above is unchanged, and the documented count
  # holds for the shipped default while compression-on adds exactly this one.
  describe "compression-gated retrieve_output tool" do
    after { described_class.reset! }

    it "does NOT register retrieve_output in the default (compression OFF) registry" do
      allow(Rubino.configuration).to receive(:tool_output_compression_enabled?).and_return(false)
      described_class.reset!
      described_class.register_defaults!

      expect(described_class.all.map(&:name)).not_to include("retrieve_output")
    end

    it "registers retrieve_output (count+1) when compression is enabled" do
      allow(Rubino.configuration).to receive(:tool_output_compression_enabled?).and_return(false)
      described_class.reset!
      described_class.register_defaults!
      default_count = described_class.all.size

      allow(Rubino.configuration).to receive(:tool_output_compression_enabled?).and_return(true)
      described_class.reset!
      described_class.register_defaults!

      expect(described_class.all.size).to eq(default_count + 1)
      expect(described_class.all.map(&:name)).to include("retrieve_output")
    end
  end
end
