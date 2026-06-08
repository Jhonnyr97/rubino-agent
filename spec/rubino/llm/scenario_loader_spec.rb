# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Rubino::LLM::ScenarioLoader do
  describe ".load" do
    it "loads a scenario from the default gem-bundled directory" do
      events = described_class.load("happy-path")
      expect(events).to be_an(Array)
      expect(events).not_to be_empty
      types = events.map { |e| e["type"] }
      expect(types).to include("content")
    end

    it "prefers an override directory over the default" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "happy-path.yml"), <<~YAML)
          events:
            - type: content
              text: "override-wins"
        YAML

        events = described_class.load("happy-path", scenarios_dir: dir)
        expect(events.size).to eq(1)
        expect(events.first["text"]).to eq("override-wins")
      end
    end

    it "raises NotFound citing both paths when the scenario is missing" do
      Dir.mktmpdir do |dir|
        expect {
          described_class.load("does-not-exist", scenarios_dir: dir)
        }.to raise_error(Rubino::LLM::ScenarioLoader::NotFound) do |err|
          expect(err.message).to include(dir)
          expect(err.message).to include(described_class::DEFAULT_DIR)
          expect(err.message).to include("does-not-exist")
        end
      end
    end
  end
end
