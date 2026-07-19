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
end

require_relative "rubino/errors"
# version.rb defines Rubino::VERSION + Rubino::TAGLINE (plain constants, not a
# Rubino::Version module), so Zeitwerk can't autoload it on a TAGLINE/VERSION
# reference. Require it eagerly here — without this an INSTALLED gem (`gem
# install rubino-agent && rubino`) crashes at CLI load with "uninitialized
# constant Rubino::TAGLINE"; it only worked under `bundle exec` because the
# gemspec's own require_relative loads it. (Ignored by the loader below.)
require_relative "rubino/version"

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
          "oauth_bearer_middleware" => "OAuthBearerMiddleware",
          "bedrock_bearer_client" => "BedrockBearerClient",
          "adapter_response" => "AdapterResponse",
          "indented_io" => "IndentedIO",
          "webfetch_tool" => "WebFetchTool",
          "websearch_tool" => "WebSearchTool",
          "skill_tool" => "SkillTool",
          "custom_tool_loader" => "CustomToolLoader",
          "custom_tool_builder" => "CustomToolBuilder",
          "tool_pair_sanitizer" => "ToolPairSanitizer",
          "degenerate_recovery" => "DegenerateResponseRecovery",
          "tool_presentation_cli" => "ToolPresentationCLI"
        )
        # Migrations are plain SQL files, not Ruby constants
        loader.ignore(
          File.expand_path("rubino/database/migrations", __dir__)
        )
        # errors.rb defines multiple constants in Rubino (NotFoundError, ...),
        # not a single Rubino::Errors module — loaded manually via require_relative.
        loader.ignore(File.expand_path("rubino/errors.rb", __dir__))
        # version.rb defines Rubino::VERSION + Rubino::TAGLINE, not a
        # Rubino::Version module — loaded manually via require_relative above.
        loader.ignore(File.expand_path("rubino/version.rb", __dir__))
        # rubino-agent.rb is a require shim matching the gem name; it maps to no
        # Rubino constant (and "Rubino-agent" isn't a valid cname). Zeitwerk must
        # not try to manage it.
        loader.ignore(File.expand_path("rubino-agent.rb", __dir__))
        # anthropic_role_merge.rb prepends RubyLLM::Providers::Anthropic at load
        # time (a side effect, not a Rubino constant) — loaded manually below.
        loader.ignore(File.expand_path("rubino/llm/anthropic_role_merge.rb", __dir__))
        # stream_tool_call_recovery.rb prepends RubyLLM::StreamAccumulator at load
        # time (a side effect, not a Rubino constant) — loaded manually below.
        loader.ignore(File.expand_path("rubino/llm/stream_tool_call_recovery.rb", __dir__))
        # tools/ subdirectories are purely organisational — the files inside define
        # flat Rubino::Tools::XxxTool constants, NOT Rubino::Tools::Subdir::XxxTool.
        # Eager-loading is handled by Tools::Registry#load_rubino_tool_files!.
        tools_root = File.expand_path("rubino/tools", __dir__)
        Dir.children(tools_root).each do |child|
          next unless File.directory?(File.join(tools_root, child))

          loader.ignore(File.expand_path("rubino/tools/#{child}", __dir__))
        end
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
      Thread.current[:rubino_ui] || (@ui ||= UI.build(configuration.dig("ui", "adapter")))
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
    # tool the child invokes (steer/probe a grandchild, spawn a nested task) can
    # find its own registry entry — the card it surfaces on, the steer queue it
    # receives notes through — without threading the id through the
    # loop/executor/tool signatures. Nil on the parent thread and on any
    # non-delegated (top-level) run.
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

    # During a background skill/memory review (the Hermes-style post-turn fork,
    # Jobs::Handlers::BackgroundReviewJob) this holds the frozen set of tool
    # names the forked review agent may dispatch. ToolExecutor consults it to
    # (a) DENY any tool outside the set and (b) treat the whitelisted
    # skill/memory tools as PRE-APPROVED trusted background writes — they only
    # touch HOME/skills and the memory store, never shell or arbitrary paths —
    # so they never reach the interactive approval gate on a thread with no
    # human to answer it (the #260 headless fail-closed floor would otherwise
    # deny them). Also the presence of a value signals "a review turn is
    # running on this thread" so Lifecycle#enqueue_post_turn_jobs skips its own
    # post-turn enqueue (no recursive reviews). Nil on every normal run.
    def review_toolset
      Thread.current[:rubino_review_toolset]
    end

    # Binds +names+ (an array of tool names) as the review toolset for the
    # duration of the block, thread-local so the forked review Runner's tools
    # reach it with zero signature churn. Mirrors Hermes'
    # set_thread_tool_whitelist + non-interactive approval callback.
    def with_review_toolset(names)
      prev = Thread.current[:rubino_review_toolset]
      Thread.current[:rubino_review_toolset] = names && names.to_set(&:to_s).freeze
      yield
    ensure
      Thread.current[:rubino_review_toolset] = prev
    end

    # The CancelToken governing best-effort AUX work (post-turn polishing:
    # memory-extract / skill-distill / summarize) running on THIS thread, if
    # any. The detached polishing thread (Interaction::Polishing) binds its
    # token here so best-effort aux work on that thread can poll it
    # and abort the moment the user presses Esc — without threading a token
    # through every aux call site. Nil on the foreground turn thread and on the
    # API/server path (no detached polishing), where aux work is uncancellable
    # as before.
    def aux_cancel_token
      Thread.current[:rubino_aux_cancel_token]
    end

    # Binds +token+ as the aux cancel token for the duration of the block
    # (set by Interaction::Polishing around its detached job drain, exactly
    # like #with_ui binds the run's UI). Thread-local so the aux retry loop
    # reaches it with zero signature churn.
    def with_aux_cancel_token(token)
      prev = Thread.current[:rubino_aux_cancel_token]
      Thread.current[:rubino_aux_cancel_token] = token
      yield
    ensure
      Thread.current[:rubino_aux_cancel_token] = prev
    end

    # The source session id that MemoryTool reads to attribute created facts to
    # the session whose turn triggered the extraction. Bound by the unified
    # review fork (BackgroundReviewJob) around the review turn; ToolExecutor
    # skips its own override when this is already set. Nil on every normal run
    # (facts from a direct user prompt get @session_id attribution).
    def memory_source_session_id
      Thread.current[:rubino_memory_source_session_id]
    end

    # Binds +session_id+ as the memory source session for the duration of the
    # block. Thread-local so MemoryTool reaches it with zero signature churn.
    def with_memory_source_session_id(session_id)
      prev = Thread.current[:rubino_memory_source_session_id]
      Thread.current[:rubino_memory_source_session_id] = session_id
      yield
    ensure
      Thread.current[:rubino_memory_source_session_id] = prev
    end

    # True while a HEADLESS one-shot run (`rubino prompt`/-q) is executing on
    # THIS thread. Bound by ChatCommand#run_oneshot via #with_headless so tools
    # that behave differently with no live REPL can tell — today only TaskTool,
    # which forces `task` subagents to run FOREGROUND in headless mode (#380): in
    # one-shot there is no IdleCardHost to fold a background child's result back
    # in and the process exits the instant the parent's answer is ready, so a
    # background fan-out would be silently dropped. Nil/false on the interactive
    # REPL and the API/server path, where background subagents are surfaced.
    def headless?
      Thread.current[:rubino_headless] || false
    end

    # Binds the headless one-shot flag for the duration of the block (set by
    # ChatCommand#run_oneshot around the turn, exactly like #with_ui). Thread-
    # local so a tool reaches it with zero signature churn through the loop.
    def with_headless
      prev = Thread.current[:rubino_headless]
      Thread.current[:rubino_headless] = true
      yield
    ensure
      Thread.current[:rubino_headless] = prev
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

    # Drops the memoized DB connection so the next #database call opens the file
    # afresh. Used by `setup` after quarantining a corrupt DB so it reconnects
    # to the newly-recreated file rather than the closed/renamed handle.
    def reset_database!
      @database&.close
      @database = nil
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

      # Seed the gem's built-in skills into ~/.rubino on every boot (marker-gated,
      # so it's a one-file-read no-op after the first time). This runs BEFORE the
      # already-set-up fast path returns, so existing homes — not just fresh
      # installs via ensure_directories! — get the built-ins materialized as
      # owned, editable files. Best-effort inside the method; never fatal.
      seed_builtin_skills!(File.join(home_path, "skills"))

      # FAST PATH (lock-free, race-safe): a side-effect-free read of
      # `schema_info` that does NOT construct a Sequel migrator. The common case
      # — an already-set-up home — returns here without touching the lock. Note
      # we MUST NOT call `migrator.pending?` off the lock: merely constructing
      # Sequel's IntegerMigrator inserts the version-0 row, and two concurrent
      # boots both inserting it is exactly the duplicate-row corruption (#race).
      if connection.healthy? && migrator.up_to_date?
        # A fully-migrated home can still be MOUNTED read-only (F14): the schema
        # reads fine, but the very next write (the session row) would crash with
        # a raw `SQLite3::ReadOnlyException` past this guard. Catch it HERE — a
        # cheap dir-writability probe, no DB write — and raise the accurate
        # "not writable" diagnosis instead, matching the migrate-path branch
        # below. A real (writable) home passes through untouched.
        unless home_writable?
          raise ConfigurationError,
                "rubino home / database is not writable: #{home_path}#{write_jail_db_hint}"
        end

        return true
      end

      ensure_directories!
      # Serialize the migration across concurrent boots (#race): N fresh
      # `rubino` processes on a brand-new home would otherwise BOTH probe +
      # migrate at once and corrupt the migrator bookkeeping. migrate! takes an
      # exclusive flock and does the `pending?` probe + migrate entirely under
      # it; waiters re-check and no-op. The lockfile lives in the home, which
      # ensure_directories! just created.
      migrator.migrate!(lock_path: migration_lock_path)
      true
    rescue Database::BusyError, ConfigurationError
      # A sustained concurrent-migration lock that outlived the connection
      # retry budget (#333/#359), or a careless RUBINO_HOME that points at a file
      # / a read-only parent (F13), is NOT an "un-set-up" home — re-raise so the
      # single CLI chokepoint surfaces the clean one-liner instead of this method
      # masking it as `false` → a misleading "run setup" message.
      raise
    rescue StandardError => e
      logger.debug(event: "ensure_database_ready_failed", error: "#{e.class}: #{e.message}")
      # A read-only / not-writable home (F14) is NOT an un-set-up install: the
      # files may be perfectly present, the directory is just mounted read-only
      # or owned by another user, so migrate! can't open the lock/journal
      # (Errno::EACCES/EROFS) or SQLite reports "attempt to write a readonly
      # database". Masking that as `false` produced the misleading
      # "isn't set up yet — run `rubino setup`" — doctor already diagnoses it
      # correctly. Raise the ACCURATE diagnosis (matching the F13 home-error
      # phrasing) so the single CLI chokepoint surfaces it instead of "not
      # set up". Everything else still degrades to false.
      if not_writable_error?(e)
        raise ConfigurationError,
              "rubino home / database is not writable: #{home_path} " \
              "(#{clean_errno_message(e.message)})#{write_jail_db_hint}"
      end

      false
    end

    # When the home/DB is read-only AND sits OUTSIDE the OS write-jail, the cause
    # is almost always a nested `rubino` launched from inside the agent's own
    # jailed shell tool: the shell is confined away from ~/.rubino, so it can't
    # write the session DB. Reuse the #74 write-jail framing so a bare "not
    # writable" becomes attributable (#Y2A). Empty string (no extra hint) unless
    # the jail is PROVEN enforcing and the home is outside its writable roots;
    # best-effort, never raises into the boot path.
    def write_jail_db_hint
      return "" unless defined?(Security::Sandbox) && Security::Sandbox.respond_to?(:enforcing?)
      return "" unless Security::Sandbox.enforcing?
      return "" if Security::Sandbox.writable?(home_path)

      " — #{home_path} is outside the workspace write-jail, so a nested rubino " \
        "launched from inside the agent's shell tool can't write the session DB " \
        "(tools.sandbox). Run rubino outside the jailed shell."
    rescue StandardError
      ""
    end

    # Cheap, side-effect-free check that the home directory accepts writes — the
    # F14 read-only-mount guard. Falls back to assuming writable on any probe
    # hiccup (the migrate path will still catch a real failure with the same
    # accurate message), so this never wrongly blocks a usable home.
    def home_writable?
      File.writable?(home_path)
    rescue StandardError
      true
    end

    # True when +error+ is a write-permission / read-only-filesystem failure
    # (vs. a genuinely un-set-up or transiently-busy home): a directory mounted
    # read-only, owned by another user, or a SQLite "readonly database" report.
    # Used by ensure_database_ready! to give an ACCURATE message instead of the
    # misleading "not set up" (F14).
    def not_writable_error?(error)
      return true if error.is_a?(Errno::EACCES) || error.is_a?(Errno::EROFS) || error.is_a?(Errno::EPERM)

      error.message.to_s.downcase.include?("readonly") ||
        error.message.to_s.downcase.include?("read-only") ||
        error.message.to_s.downcase.include?("read only")
    end

    # A clean, user-facing form of an Errno message. Ruby appends an internal
    # ` @ <syscall> - <path>` artifact to SystemCallError messages
    # (e.g. "Operation not permitted @ apply2files - /home/x",
    # "Permission denied @ dir_s_mkdir - /home/x") — the C function name and a
    # path we already name elsewhere in the sentence. Strip that tail so the
    # surfaced message is just the plain reason ("Operation not permitted").
    def clean_errno_message(message)
      message.to_s.sub(/ @ \S+ - .*\z/, "")
    end

    # Path to the inter-process migration lockfile in the rubino home. A single
    # source of truth so setup and the boot path lock on the SAME file.
    def migration_lock_path
      File.join(home_path, ".migrate.lock")
    end

    # A clean, actionable message when the on-disk DB is PRESENT but UNUSABLE,
    # else nil. Covers the un-setup-able state a user command must never crash
    # on with a raw backtrace (#333/#359): a corrupt/malformed image →
    # quarantine + recreate via setup. (The concurrent first-boot race that used
    # to leave duplicate `schema_info` rows is now prevented at the source by the
    # flock + side-effect-free `up_to_date?` fast path in the migrator, so there
    # is no post-hoc duplicate-row state left to message about.)
    # Read-only: never creates the file (matches doctor's #68 contract).
    def database_repair_message
      db = database
      return nil if db.memory? || !File.exist?(db.db_path)

      if db.corrupt?
        "database is corrupt (malformed image): #{db.db_path}\n" \
          "Run `rubino doctor` to diagnose, then `rubino setup` to quarantine it " \
          "and recreate a fresh database."
      end
    rescue StandardError
      # Detection itself must never crash a command; treat an unexpected probe
      # failure as "no clean message available" and let normal flow continue.
      nil
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

    # Resets all memoized state (useful for testing)
    def reset!
      @configuration = nil
      @ui = nil
      @database = nil
      @event_bus = nil
      @agent_registry = nil
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

    # Ensures the home directory and subdirectories exist. The home holds
    # secrets (.env) and the database, so it is forced to 0700 here — the
    # single code path every entry point (setup/chat/prompt/doctor) goes
    # through to materialize the home — not just when `setup` ran first
    # (#65): an auto-created home used to be left at the umask's 0755.
    def ensure_directories!
      home = home_path
      # A careless RUBINO_HOME (the value points at an EXISTING FILE, or its
      # parent is read-only) made FileUtils.mkdir_p raise a raw Errno::EEXIST /
      # Errno::EACCES backtrace from deep in fileutils.rb — masking the actual,
      # trivially-fixable mistake (F13). Normalize both into a clean, actionable
      # domain error AT THE SOURCE so the single CLI chokepoint surfaces one line
      # ("RUBINO_HOME is not a writable directory: <path>") + exit 1, in any
      # output format, with no trace. A directory that already exists is fine.
      if File.exist?(home) && !File.directory?(home)
        raise ConfigurationError, "RUBINO_HOME is not a writable directory: #{home} " \
                                  "(it points at an existing file — set RUBINO_HOME to a directory path)"
      end

      begin
        FileUtils.mkdir_p(home)
        # chmod/mkdir on an EXISTING read-only RUBINO_HOME (its parent let
        # mkdir_p no-op, but the dir itself is not owner-writable) raises a raw
        # Errno::EPERM/EACCES from deep in fileutils — the same unguarded
        # backtrace F13 normalized for mkdir. Keep the perm ops inside the
        # rescue so a non-writable home yields the SAME clean one-line domain
        # error + exit 1, no trace.
        File.chmod(0o700, home)
        %w[memories sessions logs skills commands tools].each do |subdir|
          dir = File.join(home, subdir)
          FileUtils.mkdir_p(dir) unless File.directory?(dir)
        end
      rescue SystemCallError => e
        raise ConfigurationError, "RUBINO_HOME is not a writable directory: #{home} (#{clean_errno_message(e.message)})"
      end

      seed_builtin_skills!(File.join(home, "skills"))
    end

    # Materialize the gem-bundled skills into the user's home so ~/.rubino is the
    # SINGLE source of truth: the user owns, edits, and deletes them as files
    # there. Runs at the home-materialization chokepoint (every entry point), so
    # a fresh install seeds on first use and a gem upgrade seeds only NEW
    # built-ins on next run.
    #
    # A `.seeded_builtins` marker records which built-ins were ever seeded, so a
    # skill the user DELETED is not resurrected on the next boot (absence ≠ "never
    # seeded"). An existing skill is never overwritten — the user's edits win. The
    # gem `skills/` dir is the seed template, no longer read at runtime (see
    # Registry#include_builtin). Best-effort: a copy failure never blocks boot.
    def seed_builtin_skills!(dest_root)
      src_root = Rubino::Skills::Registry::BUILTIN_SKILLS_DIR
      return unless File.directory?(src_root)

      FileUtils.mkdir_p(dest_root)
      marker = File.join(dest_root, ".seeded_builtins")
      seeded = File.exist?(marker) ? File.read(marker).split("\n").map(&:strip).reject(&:empty?) : []
      newly = []
      Dir.children(src_root).sort.each do |name|
        next if seeded.include?(name)             # seeded once already — respect a user delete
        src = File.join(src_root, name)
        next unless File.directory?(src)

        FileUtils.cp_r(src, File.join(dest_root, name)) unless File.exist?(File.join(dest_root, name))
        newly << name
      end
      File.write(marker, (seeded + newly).join("\n") + "\n") unless newly.empty?
    rescue StandardError => e
      logger.debug(event: "seed_builtin_skills_failed", error: "#{e.class}: #{e.message}")
    end
  end
end

# Setup autoloading
Rubino.loader.setup

# Enforce Anthropic user/assistant alternation by merging consecutive same-role
# wire messages — must run after Zeitwerk setup so RubyLLM is loadable. See the
# file for the full rationale (a tool result is a `user` message on the wire, so
# a tool result followed by another user/tool message would otherwise send two
# consecutive `user` messages and be rejected with "invalid params").
require_relative "rubino/llm/anthropic_role_merge"

# Recover tool calls a model leaks AS TEXT into its streamed content (MiniMax's
# anthropic-compatible shim) into structured calls ruby_llm's native loop runs.
# Prepends StreamAccumulator at load, so it must come after the loader is set up.
require_relative "rubino/llm/stream_tool_call_recovery"

# Register the built-in memory backends.
# The SQLite memory backend: LLM-extracted atomic facts, bi-temporal
# supersession, and hybrid FTS5 + recency recall. Switch with
# `rubino memory backend sqlite`.
Rubino::Memory::Backends.register(Rubino::Memory::Backends::Sqlite)
