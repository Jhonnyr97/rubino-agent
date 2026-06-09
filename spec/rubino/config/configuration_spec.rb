# frozen_string_literal: true

RSpec.describe Rubino::Config::Configuration do
  let(:config) { test_configuration }

  describe "model accessors" do
    it "returns model default" do
      expect(config.model_default).to eq("openai/gpt-4.1")
    end

    it "returns model temperature" do
      cfg = test_configuration("model" => {
                                 "default" => "openai/gpt-4.1",
                                 "provider" => "auto",
                                 "context_length" => nil,
                                 "temperature" => 0.3
                               })
      expect(cfg.model_temperature).to eq(0.3)
    end

    it "returns model provider" do
      expect(config.model_provider).to eq("auto")
    end
  end

  describe "compression accessors" do
    it "returns compression threshold" do
      expect(config.compression_threshold).to eq(0.50)
    end

    it "returns compression enabled" do
      expect(config.compression_enabled?).to be true
    end

    it "returns protect first/last N" do
      expect(config.compression_protect_first_n).to eq(3)
      expect(config.compression_protect_last_n).to eq(20)
    end
  end

  describe "memory accessors" do
    it "returns memory enabled" do
      expect(config.memory_enabled?).to be true
    end

    it "returns memory char limits" do
      expect(config.memory_char_limit).to eq(2200)
      expect(config.memory_user_char_limit).to eq(1375)
    end
  end

  describe "tool accessors" do
    it "returns tool enabled status" do
      expect(config.tool_enabled?("git")).to be true
      # shell ships ON by default: the agent runs in an isolated per-customer
      # VM where running commands is the whole point. It stays gated behind the
      # approval prompt via security.require_confirmation_for_shell.
      expect(config.tool_enabled?("shell")).to be true
      expect(config.tool_enabled?("browser")).to be false
    end
  end

  describe "agent budget accessors (#139 — nil falls back to default)" do
    it "returns the configured iteration/time caps" do
      expect(config.agent_max_tool_iterations).to eq(8)
      expect(config.agent_max_turn_seconds).to eq(120)
    end

    it "falls back to the built-in default when the value is nil" do
      # mirrors `config set agent.max_turn_seconds nil`, whose writer coerces
      # "nil" -> nil and used to leave a bare nil that crashed every turn.
      cfg = test_configuration("agent" => {
                                 "max_turns" => 90,
                                 "max_tool_iterations" => nil,
                                 "max_turn_seconds" => nil
                               })
      expect(cfg.agent_max_tool_iterations).to eq(8)
      expect(cfg.agent_max_turn_seconds).to eq(120)
    end
  end

  describe "nested-subagent cap accessors (S1)" do
    it "returns the built-in defaults (2 / 3 / 8)" do
      expect(config.tasks_max_depth).to eq(2)
      expect(config.tasks_max_children_per_node).to eq(3)
      expect(config.tasks_max_concurrent_total).to eq(8)
    end

    it "returns configured overrides" do
      cfg = test_configuration("tasks" => {
                                 "max_depth" => 4, "max_children_per_node" => 2, "max_concurrent_total" => 12
                               })
      expect(cfg.tasks_max_depth).to eq(4)
      expect(cfg.tasks_max_children_per_node).to eq(2)
      expect(cfg.tasks_max_concurrent_total).to eq(12)
    end

    it "falls back to the built-in default when a value is nil" do
      cfg = test_configuration("tasks" => {
                                 "max_depth" => nil, "max_children_per_node" => nil, "max_concurrent_total" => nil
                               })
      expect(cfg.tasks_max_depth).to eq(2)
      expect(cfg.tasks_max_children_per_node).to eq(3)
      expect(cfg.tasks_max_concurrent_total).to eq(8)
    end
  end

  describe "human-in-the-loop accessors" do
    it "keeps shell behind a confirmation prompt by default" do
      expect(config.require_confirmation_for_shell?).to be true
    end

    it "defaults confirm_policy to :confirm_all" do
      expect(config.confirm_policy).to eq(:confirm_all)
    end

    it "derives confirm_policy from require_confirmation_for_shell:false" do
      cfg = test_configuration("security" => { "require_confirmation_for_shell" => false })
      expect(cfg.confirm_policy).to eq(:dangerous_only)
    end

    it "honors an explicit confirm_policy and lets it win over the alias" do
      cfg = test_configuration("security" => {
                                 "confirm_policy" => "dangerous_only",
                                 "require_confirmation_for_shell" => true
                               })
      expect(cfg.confirm_policy).to eq(:dangerous_only)
    end

    it "falls back to the alias on an unrecognized confirm_policy" do
      cfg = test_configuration("security" => {
                                 "confirm_policy" => "bogus",
                                 "require_confirmation_for_shell" => false
                               })
      expect(cfg.confirm_policy).to eq(:dangerous_only)
    end

    it "waits a sane, bounded time for a human decision by default" do
      # W1: a bounded default (15 min) — long enough for a real human, but on
      # expiry the gate auto-denies and frees the worker thread. NOT the old
      # 24h that effectively never released and froze the pool, and NOT the
      # even-older 300s that failed the run.
      expect(config.approvals_wait_timeout).to eq(900.0)
      expect(config.approvals_wait_timeout).to be > 300
    end

    it "treats a nil wait timeout as wait-forever" do
      cfg = test_configuration("approvals" => { "mode" => "manual", "wait_timeout_seconds" => nil })
      expect(cfg.approvals_wait_timeout).to be_nil
    end
  end

  describe "#database_path (issue #96 — default follows RUBINO_HOME)" do
    # Build a Configuration whose raw["database"]["path"] is the sentinel
    # default, with no explicit home_path so resolution falls through to
    # Loader.default_home_path (i.e. RUBINO_HOME).
    def default_db_config
      raw = Rubino::Config::Defaults.to_hash
      Rubino::Config::Configuration.new(raw: raw, home_path: nil)
    end

    around do |example|
      prev = ENV.fetch("RUBINO_HOME", nil)
      example.run
    ensure
      if prev.nil?
        ENV.delete("RUBINO_HOME")
      else
        ENV["RUBINO_HOME"] = prev
      end
    end

    it "(a) resolves the default DB under RUBINO_HOME when no explicit path is set" do
      ENV["RUBINO_HOME"] = "/tmp/ra_home_db_spec"
      expect(default_db_config.database_path)
        .to eq(File.expand_path("/tmp/ra_home_db_spec/rubino.sqlite3"))
    end

    it "(b) an explicit database.path still wins and is expanded verbatim" do
      ENV["RUBINO_HOME"] = "/tmp/ra_home_db_spec"
      raw = Rubino::Config::Defaults.to_hash
      raw["database"] = { "path" => "/var/lib/custom/agent.sqlite3" }
      cfg = Rubino::Config::Configuration.new(raw: raw, home_path: nil)
      expect(cfg.database_path).to eq("/var/lib/custom/agent.sqlite3")
    end

    it "(c) without a RUBINO_HOME override the default lands under ~/.rubino" do
      ENV.delete("RUBINO_HOME")
      expect(default_db_config.database_path)
        .to eq(File.expand_path("~/.rubino/rubino.sqlite3"))
    end

    it "honours an explicit home_path passed at construction" do
      cfg = Rubino::Config::Configuration.new(
        raw: Rubino::Config::Defaults.to_hash, home_path: "/tmp/explicit_home"
      )
      expect(cfg.database_path)
        .to eq(File.expand_path("/tmp/explicit_home/rubino.sqlite3"))
    end
  end

  describe "#set" do
    it "sets a nested value" do
      # Configuration#set takes (*keys, value) — last arg is the value
      config.set("model", "temperature", 0.9)
      expect(config.dig("model", "temperature")).to eq(0.9)
    end
  end
end
