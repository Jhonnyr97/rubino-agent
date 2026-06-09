# frozen_string_literal: true

require "zeitwerk"
require "dry-configurable"
require "fileutils"

# Main module for the Rubino gem.
# Provides an agentic framework with persistent memory, sessions,
# context compaction, and extensible tool system built on ruby_llm.
module Rubino
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class DatabaseError < Error; end
  class SessionError < Error; end

  # Raised when --resume <query> matches more than one session by id-prefix
  # or title-substring. Carries the matches so the CLI can list them and
  # ask the user to disambiguate, instead of silently picking the first.
  class AmbiguousSessionError < SessionError
    attr_reader :query, :matches

    def initialize(query, matches)
      @query   = query
      @matches = matches
      super(build_message)
    end

    private

    def build_message
      lines = ["Ambiguous --resume '#{@query}': #{@matches.size} sessions match."]
      @matches.first(10).each do |s|
        lines << "  #{s[:id][0, 8]}  #{s[:title] || "(no title)"}  [#{s[:status]}]"
      end
      lines << "Use --resume <full-id> (8+ chars) to pick one."
      lines.join("\n")
    end
  end

  class ToolError < Error; end
  class CompactionError < Error; end
  class JobError < Error; end
end

require_relative "rubino/errors"

module Rubino
  class << self
    # Returns the Zeitwerk loader for autoloading
    def loader
      @loader ||= begin
        loader = Zeitwerk::Loader.for_gem
        loader.inflector.inflect(
          # Acronym modules
          "cli" => "CLI",
          "llm" => "LLM",
          "ui" => "UI",
          "api" => "API",
          "tls" => "TLS",
          "mcp" => "MCP",
          "oauth" => "OAuth",
          # Files with compound names that need exact mapping
          "ruby_llm_adapter" => "RubyLLMAdapter",
          "mcp_tool_wrapper" => "MCPToolWrapper",
          "bedrock_bearer_client" => "BedrockBearerClient",
          "adapter_response" => "AdapterResponse",
          "webfetch_tool" => "WebFetchTool",
          "websearch_tool" => "WebSearchTool",
          "github_tool" => "GitHubTool",
          "skill_tool" => "SkillTool",
          "custom_tool_loader" => "CustomToolLoader",
          "custom_tool_builder" => "CustomToolBuilder",
          "tool_pair_sanitizer" => "ToolPairSanitizer",
          "degenerate_recovery" => "DegenerateResponseRecovery"
        )
        # Migrations are plain SQL files, not Ruby constants
        loader.ignore(
          File.expand_path("rubino/database/migrations", __dir__)
        )
        # errors.rb defines multiple constants in Rubino (NotFoundError, ...),
        # not a single Rubino::Errors module — loaded manually via require_relative.
        loader.ignore(File.expand_path("rubino/errors.rb", __dir__))
        # rubino-agent.rb is a require shim matching the gem name; it maps to no
        # Rubino constant (and "Rubino-agent" isn't a valid cname). Zeitwerk must
        # not try to manage it.
        loader.ignore(File.expand_path("rubino-agent.rb", __dir__))
        loader
      end
    end

    # Returns the current configuration instance
    def configuration
      @configuration ||= Config::Configuration.new
    end

    # Yields the configuration for block-style setup
    def configure
      yield(configuration) if block_given?
      configuration
    end

    # Drops the memoized configuration so the next #configuration reload reads
    # config.yml / .env fresh. Used after the first-run onboarding wizard writes
    # them mid-process so the just-saved key is visible without a restart.
    def reload_configuration!
      @configuration = nil
      configuration
    end

    # Returns the current UI adapter instance.
    #
    # A thread-local override (set via #with_ui) wins over the process-global
    # adapter. This is what lets the API server run many runs concurrently:
    # each run executes in its own thread (Run::Executor#start) with its own
    # gated UI::API, and tools that reach for the global adapter
    # (QuestionTool#ask, TaskTool) resolve to THAT run's UI — not a shared,
    # gate-less global that would silently drop interactive prompts (the
    # clarify/`question` flow) and could cross-talk between runs.
    def ui
      Thread.current[:rubino_ui] || (@ui ||= UI.build(configuration.ui_adapter))
    end

    # Sets the process-global UI adapter (CLI boot, tests).
    attr_writer :ui

    # Runs the block with +adapter+ as the thread-scoped UI, restoring the
    # previous value afterwards (nested-safe). Used by Run::Executor to bind
    # the run's gated UI::API for the duration of the worker thread so global
    # `Rubino.ui` lookups inside tools hit the right, gated instance.
    def with_ui(adapter)
      prev = Thread.current[:rubino_ui]
      Thread.current[:rubino_ui] = adapter
      yield
    ensure
      Thread.current[:rubino_ui] = prev
    end

    # The EventBus of the CURRENTLY-RUNNING parent turn. The API/server path
    # injects a fresh per-run bus (Run::Executor) that its Recorder is attached
    # to; the CLI path uses the process-global bus. A backgrounded `task`
    # subagent emits its SPAWNED/COMPLETED/FAILED lifecycle events here so they
    # reach THAT run's recorder (and SSE stream) rather than a detached global
    # bus. Falls back to the global bus when no turn-scoped bus is bound.
    def active_event_bus
      Thread.current[:rubino_event_bus] || event_bus
    end

    # Binds +bus+ as the turn-scoped event bus for the duration of the block
    # (set by Interaction::Lifecycle around the loop run, like #with_ui binds
    # the UI). Thread-local so a tool reaches it with no signature churn.
    def with_event_bus(bus)
      prev = Thread.current[:rubino_event_bus]
      Thread.current[:rubino_event_bus] = bus
      yield
    ensure
      Thread.current[:rubino_event_bus] = prev
    end

    # The InputQueue of the CURRENTLY-RUNNING parent turn, if any. A background
    # subagent (TaskTool) reads this to deliver its completion notification back
    # into the parent's live loop — the parent picks it up at its next iteration
    # boundary via Loop#inject_steered_input, so the notice lands as a user
    # message between turns, NEVER between an assistant tool_use and its results.
    # Nil on the API/server path (no steering queue) — there the result is still
    # reachable via the BackgroundTasks registry / `task_result`.
    def background_sink
      Thread.current[:rubino_background_sink]
    end

    # Binds +queue+ as the background-subagent notification sink for the
    # duration of the block (set by Interaction::Lifecycle around the turn,
    # exactly like #with_ui binds the run's UI). Thread-local so a tool can
    # reach it with zero signature churn through the loop/executor.
    def with_background_sink(queue)
      prev = Thread.current[:rubino_background_sink]
      Thread.current[:rubino_background_sink] = queue
      yield
    ensure
      Thread.current[:rubino_background_sink] = prev
    end

    # The BackgroundTasks entry id of the subagent run executing on THIS thread,
    # if any. Set by TaskTool#run_child_thread around the child Runner#run! so a
    # tool the child invokes (today: ask_parent) can find its own registry entry
    # — the card it surfaces on, the steer queue it receives answers through —
    # without threading the id through the loop/executor/tool signatures. Nil on
    # the parent thread and on any non-delegated (top-level) run, which is the
    # signal ask_parent uses to refuse (a top-level agent has no parent to ask).
    def current_subagent_id
      Thread.current[:rubino_current_subagent_id]
    end

    # Binds +id+ as the current subagent id for the duration of the block
    # (set by TaskTool around the child run, exactly like #with_ui / the
    # background sink). Thread-local so the child's tools reach it with zero
    # signature churn.
    def with_current_subagent_id(id)
      prev = Thread.current[:rubino_current_subagent_id]
      Thread.current[:rubino_current_subagent_id] = id
      yield
    ensure
      Thread.current[:rubino_current_subagent_id] = prev
    end

    # Returns the current structured logger.
    def logger
      @logger ||= Logger.new
    end

    # Sets the logger (useful for testing).
    attr_writer :logger

    # Returns the database connection
    def database
      @database ||= Database::Connection.new(configuration.database_path)
    end

    # First-run guard for any DB-touching entry point. A brand-new RUBINO_HOME
    # has no schema yet (setup/chat hasn't migrated it), so a read path like
    # `rubino sessions list` would otherwise hit a raw
    # `SQLite3::SQLException: no such table` backtrace (#35). `healthy?` only
    # runs `SELECT 1`, which passes the moment SQLite lazily creates the empty
    # file — the tables are still missing — so we also check migrator.pending?.
    # Migrations are idempotent, so this is safe to call on every command. This
    # is the same logic the interactive `chat` command already used; promoted
    # here so the read CLIs (sessions/memory/jobs) share one implementation.
    # Returns true when the schema is ready, false when initialization failed
    # (callers decide whether that's fatal or degrades to an empty state).
    def ensure_database_ready!
      connection = database
      migrator   = Database::Migrator.new(connection)
      return true unless connection.healthy? == false || migrator.pending?

      ensure_directories!
      migrator.migrate!
      true
    rescue StandardError => e
      logger.debug(event: "ensure_database_ready_failed", error: "#{e.class}: #{e.message}")
      false
    end

    # Returns the event bus instance
    def event_bus
      @event_bus ||= Interaction::EventBus.new
    end

    # Returns the shared agent registry (primary/subagent/utility definitions).
    # Memoized process-wide so the `task` tool can resolve a subagent by name
    # at call time without each boot path having to thread an instance through
    # the tool executor. Both entry points (CLI ChatCommand, API ServerCommand)
    # touch this at boot so delegation works identically over /v1 and in chat;
    # the tool also reads it lazily here, so a stripped boot still resolves.
    def agent_registry
      @agent_registry ||= Agent::AgentRegistry.new
    end

    # Sets the agent registry (useful for testing / custom boots).
    attr_writer :agent_registry

    # Returns the plugin registry
    def plugin_registry
      Plugins.registry
    end

    # DSL for defining plugins
    def plugin(&)
      Plugins.registry.instance_eval(&)
    end

    # Resets all memoized state (useful for testing)
    def reset!
      @configuration = nil
      @ui = nil
      @database = nil
      @event_bus = nil
      @agent_registry = nil
      Plugins.reset!
    end

    # Returns the home directory path. Delegates to the SAME resolver the
    # config Loader uses (RUBINO_HOME → else ~/.rubino) so the server
    # (which loads config.yml through the Loader) and the CLI (config/setup/
    # doctor + ensure_directories!) never disagree about where state lives.
    # Previously this read the YAML `paths.home` default (~/.rubino) and
    # ignored $RUBINO_HOME, splitting the brain at first boot / for .env.
    def home_path
      Rubino::Config::Loader.default_home_path
    end

    # Ensures the home directory and subdirectories exist
    def ensure_directories!
      %w[memories sessions logs skills commands tools plugins].each do |subdir|
        dir = File.join(home_path, subdir)
        FileUtils.mkdir_p(dir) unless File.directory?(dir)
      end
    end
  end
end

# Setup autoloading
Rubino.loader.setup

# Register the built-in memory backends. The default backend wraps the
# existing Store/Retriever/Extractor, so an unset `memory.backend` is
# byte-identical to the pre-pluggable behavior.
Rubino::Memory::Backends.register(Rubino::Memory::Backends::Default)
# The "tiny-Zep" SQLite backend: LLM-extracted atomic facts, bi-temporal
# supersession, and hybrid FTS5 + recency recall. Switch with
# `rubino memory backend sqlite`.
Rubino::Memory::Backends.register(Rubino::Memory::Backends::Sqlite)
