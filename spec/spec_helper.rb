# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
  add_group "Config", "lib/rubino/config"
  add_group "UI", "lib/rubino/ui"
  add_group "Database", "lib/rubino/database"
  add_group "Session", "lib/rubino/session"
  add_group "Memory", "lib/rubino/memory"
  add_group "Agent", "lib/rubino/agent"
  add_group "Context", "lib/rubino/context"
  add_group "Jobs", "lib/rubino/jobs"
  add_group "Tools", "lib/rubino/tools"
  add_group "Security", "lib/rubino/security"
  add_group "Interaction", "lib/rubino/interaction"
  add_group "LLM", "lib/rubino/llm"
end

require "tmpdir"
require "rubino"
require "fileutils"
require "securerandom"

# Load all shared support files
Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

# Ensure test environment uses temporary paths
TEST_HOME = File.join(Dir.tmpdir, "rubino_test_#{Process.pid}")

# Pin RUBINO_HOME to the throwaway test home BEFORE any Config::Loader runs.
# Without this the loader falls back to ~/.rubino and reads the developer's
# real ~/.rubino/.env into ENV — so whatever keys happen to live there
# (e.g. a RUBINO_ENCRYPTION_KEY) leak into the suite and make contract
# specs (oauth encrypt/decrypt) pass or fail depending on machine state.
# `||=` still lets a developer point the suite elsewhere on purpose.
ENV["RUBINO_HOME"] ||= TEST_HOME

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = "spec/examples.txt"
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.before(:suite) do
    FileUtils.mkdir_p(TEST_HOME)
  end

  config.after(:suite) do
    FileUtils.rm_rf(TEST_HOME)
  end

  config.before do
    Rubino.reset!
    # Modes is in-process state — without this, `/mode yolo` or `--yolo` in
    # one spec leaks into every spec that runs after it under
    # `config.order = :random`, surfacing as approval-policy false-passes.
    Rubino::Modes.reset!
    # The session-scoped read-before-edit trackers are process state (#151);
    # without this a read registered in one spec could satisfy the gate in
    # another spec reusing the same session id.
    Rubino::Tools::ReadTracker.reset!
    # The remaining process-wide singletons that specs previously reset
    # ad-hoc (across ~32 files, plus the 4fcabd1 band-aid for /mode under
    # seed 62637). Centralizing here kills that order-dependence class and
    # lets coupled specs (e.g. executor_mcp_spec) run standalone. Guarded so
    # specs that don't load a given const still pass.
    Rubino::Tools::Registry.reset! if defined?(Rubino::Tools::Registry)
    Rubino::Tools::BackgroundTasks.reset! if defined?(Rubino::Tools::BackgroundTasks)
    Rubino::Run::GateRegistry.reset! if defined?(Rubino::Run::GateRegistry)
    # Use null UI and in-memory SQLite for tests
    Rubino.ui = Rubino::UI::Null.new
  end
end

# Helper to create a test database
def test_database
  connection = Rubino::Database::Connection.new(":memory:")
  migrator = Rubino::Database::Migrator.new(connection)
  migrator.migrate!
  connection
end

# Helper to create a test configuration
def test_configuration(overrides = {})
  raw = Rubino::Config::Defaults.to_hash.merge(overrides)
  raw["database"] = { "path" => ":memory:" }
  raw["paths"] = { "home" => TEST_HOME, "memory" => "#{TEST_HOME}/memories", "logs" => "#{TEST_HOME}/logs" }
  Rubino::Config::Configuration.new(raw: raw, home_path: TEST_HOME)
end
