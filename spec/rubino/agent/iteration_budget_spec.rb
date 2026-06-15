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
      # max_turns is the OUTER rail (#414) — nil it too for a truly unbounded
      # budget, else it would cap the iteration count at the default 90.
      budget.instance_variable_set(:@max_turns, nil)

      expect { budget.can_continue?(10_000) }.not_to raise_error
      expect(budget.can_continue?(10_000)).to be true
    end

    # #414: max_turns is now wired as a real OUTER rail (was dead config), and
    # extend! can never lift the count past it.
    it "enforces max_turns as the outer iteration rail even past extensions" do
      budget = described_class.new(config: test_configuration("agent" => {
                                                                "max_turns" => 5, "max_tool_iterations" => 3, "max_turn_seconds" => 600
                                                              }))
      expect(budget.can_continue?(3)).to be(true)
      budget.extend!(100) # lifts the soft iteration cap, NOT max_turns
      expect(budget.can_continue?(5)).to be(true)
      expect(budget.can_continue?(6)).to be(false)
    end

    it "ships a 600s pure-safety-net max_turn_seconds default (#408)" do
      expect(Rubino::Config::Defaults.dig("agent", "max_turn_seconds")).to eq(600)
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

    it "falls back to the config default for nil / blank (unset) overrides" do
      default = config.agent_max_tool_iterations
      [nil, ""].each do |unset|
        budget = described_class.new(config: config, max_tool_iterations: unset)
        expect(budget.can_continue?(default)).to be(true), "expected #{unset.inspect} to use config default"
        expect(budget.can_continue?(default + 1)).to be(false)
      end
    end

    it "REJECTS a 0 / negative --max-turns override with a clear message (#dx)" do
      [0, -5, 0.0, "-1"].each do |bad|
        expect { described_class.new(config: config, max_tool_iterations: bad) }
          .to raise_error(Rubino::ConfigurationError, /invalid --max-turns.*positive integer/),
              "expected #{bad.inspect} to be rejected"
      end
    end

    it "REJECTS a 0 / negative configured agent.max_turns with a clear message (#dx)" do
      [0, -3].each do |bad|
        cfg = test_configuration("agent" => { "max_turns" => bad, "max_tool_iterations" => 3 })
        expect { described_class.new(config: cfg) }
          .to raise_error(Rubino::ConfigurationError, /invalid agent\.max_turns.*positive integer/),
              "expected agent.max_turns=#{bad.inspect} to be rejected"
      end
    end
  end

  # Spec 6 (#399): #extend! raises the iteration ceiling so can_continue? is true
  # again at the cap — the "grant more budget, keep the same turn" primitive.
  describe "#extend!" do
    it "raises the iteration ceiling so can_continue? passes again at the old cap" do
      budget = described_class.new(config: config, max_tool_iterations: 3)
      expect(budget.can_continue?(4)).to be(false)

      budget.extend!(2)
      # 3 + 2 = 5: the previously-blocked iteration 4 now continues, 6 stops.
      expect(budget.can_continue?(4)).to be(true)
      expect(budget.can_continue?(5)).to be(true)
      expect(budget.can_continue?(6)).to be(false)
    end

    it "returns the new ceiling" do
      budget = described_class.new(config: config, max_tool_iterations: 3)
      expect(budget.extend!(7)).to eq(10)
    end

    it "ignores a non-positive amount (no-op) and returns the unchanged ceiling" do
      budget = described_class.new(config: config, max_tool_iterations: 3)
      [0, -5, nil, ""].each do |bad|
        expect(budget.extend!(bad)).to eq(3)
        expect(budget.can_continue?(4)).to be(false)
      end
    end

    it "is a no-op on an unbounded (nil) cap" do
      budget = described_class.new(config: config)
      budget.instance_variable_set(:@max_tool_iterations, nil)
      # Nil the outer max_turns rail too (#414) so the cap is truly unbounded.
      budget.instance_variable_set(:@max_turns, nil)
      expect(budget.extend!(5)).to be_nil
      expect(budget.can_continue?(10_000)).to be(true)
    end

    it "does NOT move the time ceiling, so extensions can't bypass max_turn_seconds" do
      tight = test_configuration("agent" => {
                                   "max_turns" => 90, "max_tool_iterations" => 1, "max_turn_seconds" => 120
                                 })
      budget = described_class.new(config: tight)
      # Simulate the wall clock already past the per-turn time ceiling.
      budget.instance_variable_set(:@turn_started_at, Time.now - 1000)
      budget.extend!(100)
      # Iteration room exists now, but the time limit still stops the turn.
      expect(budget.can_continue?(1)).to be(false)
    end
  end

  # #403 (regression): the interactive Continue prompt must fire ONLY when
  # extending would help. extend! raises only the iteration ceiling, so it helps
  # iff the ITERATION cap is the cause and time is still within budget. When the
  # TIME limit is what's spent, extending is a no-op and re-prompting loops
  # forever — #extendable? lets the Loop tell the two apart.
  describe "#extendable? / #time_exhausted? (#403)" do
    let(:tight) do
      test_configuration("agent" => {
                           "max_turns" => 90, "max_tool_iterations" => 2, "max_turn_seconds" => 120
                         })
    end

    it "is true when the iteration cap is hit and time is still within budget" do
      budget = described_class.new(config: tight)
      # iteration 3 > cap 2, clock fresh → extending (+N iterations) would help.
      expect(budget.extendable?(3)).to be(true)
      expect(budget.time_exhausted?).to be(false)
    end

    it "is false when the iteration cap is NOT yet hit (nothing to extend)" do
      budget = described_class.new(config: tight)
      expect(budget.extendable?(2)).to be(false)
    end

    it "is false when the TIME limit is exhausted — extend! can't move the clock" do
      budget = described_class.new(config: tight)
      # Wall clock already past max_turn_seconds; iteration cap also blown.
      budget.instance_variable_set(:@turn_started_at, Time.now - 1000)
      expect(budget.time_exhausted?).to be(true)
      # Even with the iteration cap exceeded, extending is a no-op vs the clock,
      # so the prompt must NOT be offered.
      expect(budget.extendable?(3)).to be(false)
    end

    it "is false on an unbounded (nil) iteration cap — nothing to extend" do
      budget = described_class.new(config: tight)
      budget.instance_variable_set(:@max_tool_iterations, nil)
      # Nil the outer max_turns rail too (#414), else within_iteration_limit?
      # would still be false at 10_000 and extendable? could read true.
      budget.instance_variable_set(:@max_turns, nil)
      expect(budget.extendable?(10_000)).to be(false)
    end

    it "flips to false once a previously-extendable turn blows the time limit" do
      budget = described_class.new(config: tight)
      expect(budget.extendable?(3)).to be(true)
      # The same turn keeps running and now exceeds max_turn_seconds.
      budget.instance_variable_set(:@turn_started_at, Time.now - 1000)
      expect(budget.extendable?(3)).to be(false)
    end

    # #403 (reintroduction guard): extend! lifts only the SOFT ceiling, never the
    # max_turns OUTER rail. Once a user has extended the soft cap PAST max_turns,
    # any iteration > max_turns must report extendable? = false so the Loop
    # force-summarizes — otherwise the rail keeps blocking, extendable? stays
    # true, and the Continue prompt loops forever (the live infinite-loop bug).
    it "is false past max_turns even with the soft cap extended above it" do
      budget = described_class.new(config: test_configuration("agent" => {
                                                                "max_turns" => 90, "max_tool_iterations" => 25, "max_turn_seconds" => 600
                                                              }))
      # User extends the soft cap well past the max_turns outer rail.
      budget.extend!(100) # 25 + 100 = 125 soft ceiling, still capped at 90 turns
      # Iteration 91 is past max_turns: the OUTER rail (not the soft ceiling) is
      # the blocker, and extend! is impotent against it — so NO re-prompt.
      expect(budget.extendable?(91)).to be(false)
      # And the outer rail still hard-stops the runaway.
      expect(budget.can_continue?(91)).to be(false)
    end

    it "is true in the normal case: soft cap exhausted but still within max_turns" do
      budget = described_class.new(config: test_configuration("agent" => {
                                                                "max_turns" => 90, "max_tool_iterations" => 25, "max_turn_seconds" => 600
                                                              }))
      # Soft cap 25 exhausted at iteration 26, which is well within max_turns 90:
      # the soft ceiling is the blocker, so extending genuinely helps.
      expect(budget.extendable?(26)).to be(true)
    end
  end
end
