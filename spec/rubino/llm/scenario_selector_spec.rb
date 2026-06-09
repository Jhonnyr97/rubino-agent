# frozen_string_literal: true

RSpec.describe Rubino::LLM::ScenarioSelector do
  describe ".resolve" do
    it "returns the default scenario for blank input" do
      expect(described_class.resolve("")).to eq("happy-path")
      expect(described_class.resolve(nil)).to eq("happy-path")
    end

    it "routes quota-exceeded keywords ahead of generic 'error'" do
      expect(described_class.resolve("simulate a quota exceeded error")).to eq("provider-quota-completed")
    end

    it "routes cron-failure before generic 'fail'" do
      expect(described_class.resolve("please simulate a broken cron job")).to eq("agent-creates-cron-failure")
    end

    it "routes generic 'fail' to the failure scenario when no more specific rule matches" do
      expect(described_class.resolve("the deploy will crash")).to eq("failure")
    end

    it "matches case-insensitively" do
      expect(described_class.resolve("Please APPROVE this action")).to eq("with-approvals")
    end

    it "with-reasoning wins over with-clarify for the shared 'what do you think' keyword" do
      # Both rules contain "what do you think"; with-reasoning is listed first
      # in ROUTER so it must win — preserves the upstream ordering noted in
      # fake-provider-spec.md.
      expect(described_class.resolve("what do you think?")).to eq("with-reasoning")
    end

    it "falls back to the supplied default when no keywords match" do
      expect(described_class.resolve("hello world", default: "custom")).to eq("custom")
    end
  end

  describe "ROUTER integrity" do
    # Guard against a route that points at a scenario file that doesn't exist:
    # with the fake provider, such a route makes ScenarioLoader#load raise
    # NotFound at runtime and kills the run. Fail at CI instead.
    it "maps every routed scenario to an existing scenario YAML" do
      missing = described_class::ROUTER.map { |rule| rule[:scenario] }.uniq.reject do |name|
        path = File.join(Rubino::LLM::ScenarioLoader::DEFAULT_DIR, "#{name}.yml")
        File.file?(path)
      end

      expect(missing).to be_empty,
                         "ROUTER references scenarios with no YAML under " \
                         "#{Rubino::LLM::ScenarioLoader::DEFAULT_DIR}: #{missing.inspect}"
    end
  end
end
