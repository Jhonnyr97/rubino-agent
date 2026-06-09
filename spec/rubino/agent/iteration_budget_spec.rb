# frozen_string_literal: true

RSpec.describe Rubino::Agent::IterationBudget do
  let(:config) { Rubino.configuration }

  describe "#can_continue?" do
    it "stops once the iteration cap is exceeded" do
      budget = described_class.new(config: test_configuration("agent" => {
                                                                "max_turns" => 90, "max_tool_iterations" => 3, "max_turn_seconds" => 120
                                                              }))
      expect(budget.can_continue?(3)).to be true
      expect(budget.can_continue?(4)).to be false
    end

    # #139: a nil iteration/time cap (e.g. `config set agent.max_turn_seconds nil`)
    # must NOT crash the turn with "comparison of Float with nil failed". The
    # config getter falls back to the default, and the budget itself treats a
    # nil cap as unbounded defensively.
    it "does not crash when the caps are nil and treats them as unbounded" do
      raw = Rubino::Config::Defaults.to_hash.merge(
        "agent" => { "max_turns" => 90, "max_tool_iterations" => nil, "max_turn_seconds" => nil }
      )
      raw["database"] = { "path" => ":memory:" }
      config = Rubino::Config::Configuration.new(raw: raw, home_path: TEST_HOME)

      # Force the in-memory limits to nil to exercise IterationBudget's own guard
      # independent of the config getter's fallback.
      budget = described_class.new(config: config)
      budget.instance_variable_set(:@max_tool_iterations, nil)
      budget.instance_variable_set(:@max_turn_seconds, nil)

      expect { budget.can_continue?(10_000) }.not_to raise_error
      expect(budget.can_continue?(10_000)).to be true
    end
  end

  describe "max_tool_iterations override (#141 --max-turns wiring)" do
    it "uses the config default when no override is given" do
      budget = described_class.new(config: config)
      default = config.agent_max_tool_iterations
      expect(budget.can_continue?(default)).to be(true)
      expect(budget.can_continue?(default + 1)).to be(false)
    end

    it "caps iterations at an explicit override below the config default" do
      budget = described_class.new(config: config, max_tool_iterations: 1)
      expect(budget.can_continue?(1)).to be(true)
      expect(budget.can_continue?(2)).to be(false)
    end

    it "accepts the Thor numeric (Float) override and treats it as an integer cap" do
      budget = described_class.new(config: config, max_tool_iterations: 2.0)
      expect(budget.can_continue?(2)).to be(true)
      expect(budget.can_continue?(3)).to be(false)
    end

    it "raises the cap above the config default when asked" do
      high = config.agent_max_tool_iterations + 50
      budget = described_class.new(config: config, max_tool_iterations: high)
      expect(budget.can_continue?(config.agent_max_tool_iterations + 1)).to be(true)
      expect(budget.can_continue?(high)).to be(true)
      expect(budget.can_continue?(high + 1)).to be(false)
    end

    it "falls back to the config default for nil / zero / negative overrides" do
      default = config.agent_max_tool_iterations
      [nil, 0, -5, ""].each do |bad|
        budget = described_class.new(config: config, max_tool_iterations: bad)
        expect(budget.can_continue?(default)).to be(true), "expected #{bad.inspect} to use config default"
        expect(budget.can_continue?(default + 1)).to be(false)
      end
    end
  end
end
