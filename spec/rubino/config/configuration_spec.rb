# frozen_string_literal: true

RSpec.describe Rubino::Config::Configuration do
  let(:config) { test_configuration }

  describe "model accessors" do
    it "returns model default" do
      expect(config.dig("model", "default")).to eq("openai/gpt-4.1")
    end

    it "defaults temperature to nil (inherit provider default, #414)" do
      expect(config.dig("model", "temperature")).to be_nil
    end

    it "returns model temperature" do
      cfg = test_configuration("model" => {
                                 "default" => "openai/gpt-4.1",
                                 "provider" => "auto",
                                 "context_length" => nil,
                                 "temperature" => 0.3
                               })
      expect(cfg.dig("model", "temperature")).to eq(0.3)
    end

    it "returns model provider" do
      expect(config.dig("model", "provider")).to eq("auto")
    end
  end

  describe "display accessors (statusbar + input growth)" do
    it "statusbar defaults to enabled" do
      expect(config.display_statusbar?).to be true
    end

    it "only an explicit false disables the statusbar" do
      cfg = test_configuration("display" => { "statusbar" => false })
      expect(cfg.display_statusbar?).to be false
    end

    it "input_max_rows reads the configured cap" do
      cfg = test_configuration("display" => { "input_max_rows" => 12 })
      expect(cfg.display_input_max_rows).to eq(12)
    end

    it "input_max_rows falls back to the composer default for nil/zero/garbage" do
      expect(config.display_input_max_rows).to eq(Rubino::UI::BottomComposer::MAX_INPUT_ROWS)
      cfg = test_configuration("display" => { "input_max_rows" => 0 })
      expect(cfg.display_input_max_rows).to eq(Rubino::UI::BottomComposer::MAX_INPUT_ROWS)
      cfg = test_configuration("display" => { "input_max_rows" => "junk" })
      expect(cfg.display_input_max_rows).to eq(Rubino::UI::BottomComposer::MAX_INPUT_ROWS)
    end

    it "live_markdown defaults to enabled" do
      expect(config.display_live_markdown?).to be true
    end

    it "only an explicit false falls back to the raw live tail" do
      expect(test_configuration("display" => { "live_markdown" => false })
               .display_live_markdown?).to be false
      expect(test_configuration("display" => { "live_markdown" => true })
               .display_live_markdown?).to be true
    end

    it "synchronized_output defaults to enabled" do
      expect(config.display_synchronized_output?).to be true
    end

    it "only an explicit false disables synchronized output" do
      expect(test_configuration("display" => { "synchronized_output" => false })
               .display_synchronized_output?).to be false
    end

    it "code_highlight defaults to enabled" do
      expect(config.display_code_highlight?).to be true
    end

    it "only an explicit false disables code highlighting" do
      expect(test_configuration("display" => { "code_highlight" => false })
               .display_code_highlight?).to be false
    end
  end

  describe "#chat_auto_resume?" do
    it "defaults to true (bare chat auto-resumes the last session for the dir)" do
      expect(config.chat_auto_resume?).to be true
    end

    it "only an explicit false disables auto-resume" do
      cfg = test_configuration("chat" => { "auto_resume" => false })
      expect(cfg.chat_auto_resume?).to be false
    end
  end

  describe "notification accessors (attention bell + command hook)" do
    it "defaults: enabled, bell on, no command, 10s long-turn threshold" do
      expect(config.notifications_enabled?).to be true
      expect(config.notifications_bell?).to be true
      expect(config.notifications_command).to be_nil
      expect(config.notifications_min_turn_seconds).to eq(10.0)
    end

    it "only an explicit false disables the channel switches" do
      cfg = test_configuration("notifications" => { "enabled" => false, "bell" => false })
      expect(cfg.notifications_enabled?).to be false
      expect(cfg.notifications_bell?).to be false
    end

    it "returns the configured command, treating blank as nil" do
      cfg = test_configuration("notifications" => { "command" => "notify-send rubino" })
      expect(cfg.notifications_command).to eq("notify-send rubino")
      expect(test_configuration("notifications" => { "command" => "" }).notifications_command).to be_nil
    end

    it "min_turn_seconds reads the override and falls back to the default for nil" do
      cfg = test_configuration("notifications" => { "min_turn_seconds" => 30 })
      expect(cfg.notifications_min_turn_seconds).to eq(30.0)
      expect(test_configuration("notifications" => {}).notifications_min_turn_seconds).to eq(10.0)
    end
  end

  describe "compression accessors" do
    it "returns compression threshold" do
      expect(config.dig("compression", "threshold")).to eq(0.50)
    end

    it "returns compression enabled" do
      expect(config.compression_enabled?).to be true
    end

    it "returns protect first/last N" do
      expect(config.dig("compression", "protect_first_n")).to eq(3)
      expect(config.dig("compression", "protect_last_n")).to eq(20)
    end
  end

  describe "tool-output code-compression accessors" do
    it "defaults the skeletoner languages to [ruby]" do
      expect(config.tool_output_compression_code_languages).to eq(%w[ruby])
    end

    it "reads the languages list from the code block" do
      cfg = test_configuration("tool_output_compression" => { "code" => { "languages" => %w[ruby python] } })
      expect(cfg.tool_output_compression_code_languages).to eq(%w[ruby python])
    end

    it "returns [] when the languages key is absent" do
      cfg = test_configuration("tool_output_compression" => { "code" => {} })
      expect(cfg.tool_output_compression_code_languages).to eq([])
    end
  end

  describe "memory accessors" do
    it "returns memory enabled" do
      expect(config.memory_enabled?).to be true
    end

    it "returns memory char limits" do
      expect(config.dig("memory", "memory_char_limit")).to eq(2200)
      expect(config.dig("memory", "user_char_limit")).to eq(1375)
    end
  end

  # #skills_enabled? is the master switch SkillTool gates its authoring
  # actions (create/edit/patch/write_file/delete) on, and skills_auto_distill?
  # / prompt_assembler's skills_feature_enabled? both delegate to it now — one
  # source of truth for "is the skills feature on" (default true).
  describe "skills accessors" do
    it "defaults to enabled when the key is absent" do
      expect(config.skills_enabled?).to be true
    end

    it "is disabled only on an explicit false" do
      expect(test_configuration("skills" => { "enabled" => false }).skills_enabled?).to be false
      expect(test_configuration("skills" => { "enabled" => true }).skills_enabled?).to be true
    end

    it "skills_auto_distill? stays false whenever skills_enabled? is false, regardless of auto_distill" do
      cfg = test_configuration("skills" => { "enabled" => false, "auto_distill" => true })
      expect(cfg.skills_auto_distill?).to be false
    end
  end

  describe "tool accessors" do
    it "returns tool enabled status" do
      expect(config.tool_enabled?("ruby")).to be true
      # shell ships ON by default: the agent runs in an isolated per-customer
      # VM where running commands is the whole point. Dangerous commands stay
      # gated behind the approval prompt via security.confirm_policy.
      expect(config.tool_enabled?("shell")).to be true
      expect(config.tool_enabled?("browser")).to be false
    end
  end

  # CFG-R3-1 — a YAML scalar (`command_allowlist: git status`) where a sequence
  # was meant must not reach the matcher as a bare String (String#filter_map ->
  # NoMethodError out of the approval path). The accessor always returns an Array.
  describe "security_command_allowlist coercion (CFG-R3-1)" do
    it "returns the sequence as-is when it is already an array" do
      cfg = test_configuration("security" => { "command_allowlist" => ["git status", "git diff"] })
      expect(cfg.security_command_allowlist).to eq(["git status", "git diff"])
    end

    it "coerces a scalar string to a single-entry array (not a bare String)" do
      cfg = test_configuration("security" => { "command_allowlist" => "git status" })
      expect(cfg.security_command_allowlist).to eq(["git status"])
    end

    it "returns an empty array when the key is absent / nil" do
      expect(test_configuration("security" => {}).security_command_allowlist).to eq([])
      expect(test_configuration("security" => { "command_allowlist" => nil }).security_command_allowlist).to eq([])
    end
  end

  describe "agent budget accessors (#139 — nil falls back to default)" do
    it "returns the configured iteration/time caps" do
      # Iteration budget aligned to the Hermes reference (90); the per-turn wall
      # clock is DISABLED by default (nil) so it can't guillotine legitimate long
      # work — the iteration budget is the runaway guard (#408 / Hermes parity).
      expect(config.agent_max_tool_iterations).to eq(90)
      expect(config.agent_max_turn_seconds).to be_nil
    end

    it "falls back to the built-in default when the value is nil" do
      # mirrors `config set agent.max_turn_seconds nil`, whose writer coerces
      # "nil" -> nil and used to leave a bare nil that crashed every turn.
      cfg = test_configuration("agent" => {
                                 "max_turns" => 90,
                                 "max_tool_iterations" => nil,
                                 "max_turn_seconds" => nil
                               })
      expect(cfg.agent_max_tool_iterations).to eq(90)
      # max_turn_seconds default is now nil (disabled), so a nil config value
      # resolves to nil — the wall clock stays off rather than snapping to 600.
      expect(cfg.agent_max_turn_seconds).to be_nil
    end
  end

  # #399: interactive budget-extension knobs.
  describe "budget-extension accessors (#399)" do
    it "defaults the prompt ON and the step to max_tool_iterations" do
      expect(config.agent_budget_extension_prompt?).to be(true)
      expect(config.agent_budget_extension_step).to eq(config.agent_max_tool_iterations)
    end

    it "honours an explicit prompt:false (force the old always-summarize)" do
      cfg = test_configuration("agent" => { "budget_extension_prompt" => false })
      expect(cfg.agent_budget_extension_prompt?).to be(false)
    end

    it "uses an explicit positive step and ignores a bad one" do
      expect(test_configuration("agent" => { "budget_extension_step" => 10 })
        .agent_budget_extension_step).to eq(10)
      bad = test_configuration("agent" => { "budget_extension_step" => 0 })
      expect(bad.agent_budget_extension_step).to eq(bad.agent_max_tool_iterations)
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
    # item 7: confirm_policy is the SOLE source of truth — the legacy
    # security.require_confirmation_for_shell alias was removed (no back-compat
    # mapping, no derivation).
    it "defaults confirm_policy to :dangerous_only (#409 Hermes alignment)" do
      expect(config.confirm_policy).to eq(:dangerous_only)
    end

    it "honors an explicit confirm_all" do
      cfg = test_configuration("security" => { "confirm_policy" => "confirm_all" })
      expect(cfg.confirm_policy).to eq(:confirm_all)
    end

    it "honors an explicit dangerous_only" do
      cfg = test_configuration("security" => { "confirm_policy" => "dangerous_only" })
      expect(cfg.confirm_policy).to eq(:dangerous_only)
    end

    it "falls back to the :dangerous_only default on an unrecognized confirm_policy" do
      cfg = test_configuration("security" => { "confirm_policy" => "bogus" })
      expect(cfg.confirm_policy).to eq(:dangerous_only)
    end

    it "IGNORES the removed require_confirmation_for_shell key (no silent honor)" do
      # Even set to true (which the legacy alias mapped to confirm_all), the
      # removed key has zero effect: confirm_policy stays the seeded default.
      cfg = test_configuration("security" => { "require_confirmation_for_shell" => true })
      expect(cfg.confirm_policy).to eq(:dangerous_only)
      expect(cfg).not_to respond_to(:require_confirmation_for_shell?)
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

  describe "auxiliary.embedding defaults" do
    it "exists with inert defaults (provider: main, model: empty)" do
      cfg = config.auxiliary_config("embedding")
      expect(cfg).to be_a(Hash)
      expect(cfg["provider"]).to eq("main")
      expect(cfg["model"]).to eq("")
      expect(cfg["base_url"]).to be_nil
      expect(cfg["timeout"]).to eq(30)
    end

    it "at defaults, the memory SQLite vector gate is false (no embed calls)" do
      # With the shipped defaults (memory.sqlite.vector: false), vector?
      # is false and no embedding is ever computed — stock behaviour unchanged.
      expect(config.dig("memory", "sqlite", "vector")).to be(false)
    end

    it "is configurable per aux pattern: provider, model, base_url all settable" do
      cfg = test_configuration(
        "auxiliary" => {
          "embedding" => {
            "provider" => "openai",
            "model" => "bge-m3",
            "base_url" => "http://localhost:8080/v1",
            "timeout" => 60
          }
        },
        "memory" => {
          "sqlite" => { "vector" => true }
        }
      )
      emb = cfg.auxiliary_config("embedding")
      expect(emb["provider"]).to eq("openai")
      expect(emb["model"]).to eq("bge-m3")
      expect(emb["base_url"]).to eq("http://localhost:8080/v1")
      expect(emb["timeout"]).to eq(60)
      expect(cfg.dig("memory", "sqlite", "vector")).to be(true)
    end
  end
end
