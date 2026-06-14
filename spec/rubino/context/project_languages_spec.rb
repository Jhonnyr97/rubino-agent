# frozen_string_literal: true

RSpec.describe Rubino::Context::ProjectLanguages do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  attr_reader :dir

  describe ".detect" do
    it "detects ruby from a Gemfile" do
      File.write(File.join(dir, "Gemfile"), "source 'https://rubygems.org'")
      expect(described_class.detect(root: dir)).to include("ruby")
    end

    it "detects python from requirements.txt" do
      File.write(File.join(dir, "requirements.txt"), "flask")
      expect(described_class.detect(root: dir)).to include("python")
      expect(described_class.detect(root: dir)).not_to include("ruby")
    end

    it "detects python from pyproject.toml" do
      File.write(File.join(dir, "pyproject.toml"), "[project]\nname='x'")
      expect(described_class.detect(root: dir)).to include("python")
    end

    it "detects javascript from package.json" do
      File.write(File.join(dir, "package.json"), "{}")
      expect(described_class.detect(root: dir)).to include("javascript")
    end

    it "falls back to source-file extensions when no marker file exists" do
      File.write(File.join(dir, "app.py"), "print(1)")
      expect(described_class.detect(root: dir)).to contain_exactly("python")
    end

    it "prefers marker files over a stray extension match" do
      File.write(File.join(dir, "Gemfile"), "x")
      File.write(File.join(dir, "script.py"), "print(1)")
      # Once a marker is found we don't also scan extensions: a Ruby project
      # with a one-off helper script is still a Ruby project.
      expect(described_class.detect(root: dir)).to contain_exactly("ruby")
    end

    it "returns empty for a bare directory (unknown language)" do
      expect(described_class.detect(root: dir)).to be_empty
    end

    it "returns empty (never raises) for a missing root" do
      expect(described_class.detect(root: File.join(dir, "nope"))).to be_empty
    end
  end

  describe ".uses?" do
    it "is case-insensitive and reflects detection" do
      File.write(File.join(dir, "Gemfile"), "x")
      expect(described_class.uses?("Ruby", root: dir)).to be(true)
      expect(described_class.uses?("python", root: dir)).to be(false)
    end
  end
end
