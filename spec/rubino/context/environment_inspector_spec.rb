# frozen_string_literal: true

RSpec.describe Rubino::Context::EnvironmentInspector do
  before { described_class.reset_cache! }
  after  { described_class.reset_cache! }

  describe "#render" do
    it "includes today's date in ISO format" do
      frozen = Time.new(2026, 6, 3, 12, 0, 0)
      inspector = described_class.new(clock: -> { frozen })
      expect(inspector.render).to include("Today's date: 2026-06-03")
    end

    it "lists the working directory" do
      Dir.mktmpdir do |tmp|
        rendered = described_class.new(cwd: tmp).render
        expect(rendered).to include("Working dir: #{tmp}")
      end
    end

    it "advertises the in-process read_attachment document capability + formats (#6)" do
      rendered = described_class.new.render
      expect(rendered).to include("read_attachment")
      expect(rendered).to include("converts these formats to Markdown in-process")
      # at minimum the always-available pure-ruby formats are listed
      expect(rendered).to match(/csv|html|json/)
    end

    it "detects a git working tree" do
      Dir.mktmpdir do |tmp|
        Dir.mkdir(File.join(tmp, ".git"))
        rendered = described_class.new(cwd: tmp).render
        expect(rendered).to include("Git:")
      end
    end

    it "omits the Git line when cwd has no .git" do
      Dir.mktmpdir do |tmp|
        rendered = described_class.new(cwd: tmp).render
        expect(rendered).not_to match(/^- Git:/)
      end
    end

    it "renders the [Environment] section header" do
      expect(described_class.new.render).to start_with("[Environment]")
    end
  end

  describe "#available_utilities" do
    it "returns only utilities present on PATH" do
      # `ruby` is guaranteed available — we're running under it.
      utilities = described_class.new.available_utilities
      expect(utilities).to include("ruby")
    end

    it "probes extras alongside the defaults" do
      described_class.reset_cache!
      inspector = described_class.new(extra_utilities: %w[ruby this-binary-does-not-exist-zzz])
      expect(inspector.available_utilities).to include("ruby")
      expect(inspector.available_utilities).not_to include("this-binary-does-not-exist-zzz")
    end

    it "caches the probe result across instances within a process" do
      first = described_class.new.available_utilities.object_id
      second = described_class.new.available_utilities.object_id
      expect(first).to eq(second)
    end

    it "sorts the utility list for cache-stable prompts" do
      utilities = described_class.new.available_utilities
      expect(utilities).to eq(utilities.sort)
    end
  end
end
