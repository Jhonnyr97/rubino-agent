# frozen_string_literal: true

module Rubino
  module Agent
    # Top-level orchestrator for a single user interaction.
    # Coordinates session management, the agent loop, and post-turn jobs.
    class Runner
      attr_reader :session

      # The resolved model id this runner runs against. Read by SubagentProbe so an
      # ephemeral peek uses the child's OWN model, not the global default.
      attr_reader :model_id

      def initialize(session_id: nil, model_override: nil, provider_override: nil,
                     max_turns: nil, ignore_rules: false, ui: nil, agent_definition: nil,
                     event_bus: nil, announce_session: true, session_source: "cli",
                     interactive: false, system_prompt_override: nil,
                     message_store: nil)
        @ui = ui || Rubino.ui
        # An in-chat rewind/fork builds a runner on the child session but has its
        # own purpose-built "┄ rewound to message N — editing ┄" marker, so the
        # generic "Resuming session: <id>…" plumbing line must not also leak into
        # the transcript (#220). Off-rewind callers keep the announcement.
        @announce_session = announce_session
        # Defaults to the process-global bus for the single-run CLI path; the
        # HTTP Executor injects a fresh per-run bus so concurrent runs don't
        # cross-contaminate each other's events/output (architecture audit A1).
        @event_bus = event_bus || Rubino.event_bus
        @config = Rubino.configuration
        @session_repo = Session::Repository.new
        @message_store = message_store || Session::Store.new
        @explicit_model_override = model_override
        @model_id = model_override || @config.dig("model", "default")
        @provider_override = provider_override
        @max_turns = max_turns
        @ignore_rules = ignore_rules
        @agent_definition = agent_definition
        # Byte-identical system prompt for the Hermes-style background review
        # fork (nil on every normal runner). Threaded into each turn's Lifecycle
        # so the review request's prefix matches the parent turn's warm cache.
        @system_prompt_override = system_prompt_override
        # The `source` stamped on a freshly-created session row. Defaults to
        # "cli" (a user-driven REPL/one-shot session); the `task` tool passes
        # "subagent" so internal subagent prompt-sessions can be filtered out of
        # the user-facing /sessions picker + `sessions list` (they're machinery,
        # not the user's own conversations) while staying resumable by explicit
        # id. Like Claude Code hiding its Task subagent sessions from the picker.
        @session_source = session_source
        # True only for the interactive REPL, where more in-process turns follow
        # this one. Lifecycle uses it to keep automatic memory extraction OFF the
        # live KV-cache slot between turns (#608c) — a headless one-shot, which
        # exits after its single turn, leaves it false and extracts normally.
        @interactive = interactive
        # Pre-instantiate so cancel! is meaningful between turns and during the
        # window between Signal.trap install and run() — a too-early Ctrl+C
        # used to land on a nil token and silently no-op, then the next run
        # started fresh and the user's cancel was lost.
        @cancel_token = Interaction::CancelToken.new
        # Detached post-turn polishing worker (#319): owns the background thread
        # that drains memory-extract / skill-distill / summarize OFF the live
        # turn so the next prompt is never gated, and is cancellable via Esc.
        # Reused across this runner's turns so #running? / #cancel! address the
        # CURRENT polishing run (coalescing rapid turns).
        @polishing = Interaction::Polishing.new(config: @config)
        @session = load_or_create_session(session_id)
      end

      # The detached post-turn polishing worker, so the CLI can show the
      # non-blocking "polishing… (Esc to skip)" indicator while it runs and
      # extend the single Esc/cancel path to it (#319).
      attr_reader :polishing

      # Executes a full interaction turn, swallowing failures so CLI callers
      # can stay in the REPL after a model/tool error. The friendly UI
      # message is emitted, but the bus event INTERACTION_FAILED is NOT
      # re-emitted here — Interaction::Lifecycle is the single source of
      # truth for that, and it already emitted before re-raising. Use
      # +run!+ from non-CLI callers (HTTP executor) that need the
      # exception to propagate so the run row can be marked failed.
      def run(input, image_paths: [], input_queue: nil, paste_expansions: [])
        run!(input, image_paths: image_paths, input_queue: input_queue,
                    paste_expansions: paste_expansions)
      rescue Interrupted
        # Standardized single interrupt notice: a dim `⎿ interrupted` marker
        # right after the partial answer the Loop already committed via
        # #stream_end. Replaces the old "⚠ interrupted by user" warning so the
        # Ctrl+C path and the interrupt-by-default type-ahead path read the same.
        @ui.turn_interrupted
        nil
      rescue SystemExit, Interrupt, SignalException
        raise
      rescue Exception => e # rubocop:disable Lint/RescueException
        # Record an AUTH/credential failure so the interactive REPL can exit
        # NON-ZERO on teardown (field standard: a CLI that surfaced an auth error
        # must not report success — git/gh/Claude Code/Codex all exit non-zero).
        # We do NOT exit here: the swallow-and-stay-in-the-REPL contract above is
        # deliberate (the user can fix their key and retry without relaunching),
        # so the failure is LATCHED and the process exits 1 at clean teardown
        # instead of mid-turn. A subsequent successful turn does NOT clear it —
        # the run as a whole still hit a credential error the caller should see.
        @auth_error = true if auth_credential_error?(e)
        @ui.error(friendly_error_message(e))
        nil
      end

      # True when an AUTH/credential error was surfaced during this runner's
      # lifetime (read by the interactive REPL to exit non-zero on teardown).
      # Latched by #run; never reset.
      def auth_error?
        @auth_error == true
      end

      # Like +run+ but propagates exceptions to the caller. The HTTP
      # Executor uses this so it can transition the run row to "failed"
      # (instead of mark_completed!) when the lifecycle raises. The
      # ScriptError / Exception net is kept here too so the Executor sees
      # LoadError etc. as a real failure rather than nil-and-completed.
      def run!(input, image_paths: [], input_queue: nil, paste_expansions: [])
        # Each turn gets a fresh token. A CancelToken is one-shot, so reusing a
        # cancelled one would poison every subsequent turn (it would raise
        # Interrupted immediately at the first poll point). The per-turn SIGINT
        # trap (CLI) / stop-watcher (HTTP) is wired to #cancel! against this new
        # token before any LLM/tool work runs, so an in-flight interrupt still
        # cancels the current turn.
        @cancel_token = Interaction::CancelToken.new

        lifecycle = Interaction::Lifecycle.new(
          session: @session,
          event_bus: @event_bus,
          ui: @ui,
          config: @config,
          ignore_rules: @ignore_rules,
          agent_definition: @agent_definition,
          cancel_token: @cancel_token,
          model_override: @explicit_model_override,
          provider_override: @provider_override,
          interactive: @interactive,
          # The SOFT iteration ceiling (where the budget-extension prompt fires)
          # vs the HARD max_turns outer rail (config agent.max_turns, applied
          # inside IterationBudget). @max_turns carries the per-run soft cap on
          # BOTH paths:
          #   - MAIN agent: the `--max-turns N` override (nil ⇒ config default).
          #   - SUBAGENT:   definition.max_turns — e.g. explore=20, general=50,
          #     BELOW the 90 hard rail — so the child both HONORS its per-agent
          #     cap (#571: it used to be dropped entirely) AND can surface the
          #     #574 budget-park at that cap, extendable up to the 90 outer rail.
          # A subagent that sets no max_turns falls back to config agent.max_turns
          # (soft == hard) and simply hard-stops there, like the main agent.
          max_tool_iterations: @max_turns,
          polishing: @polishing,
          system_prompt_override: @system_prompt_override,
          message_store: @message_store
        )

        response = lifecycle.execute(input, image_paths: image_paths, input_queue: input_queue,
                                            paste_expansions: paste_expansions)

        # Adopt an automatic-compaction swap so the NEXT turn runs on the (small)
        # compaction child, not the dead parent (P3 F1). When #check_and_compact
        # fires, it reassigns the lifecycle's session to the child; without
        # picking that up here the Runner would rebuild every subsequent turn's
        # Lifecycle on the un-shrunk parent → re-compact every turn (superlinear
        # DB/context bloat + ~2.9x slowdown). This is the automatic-path
        # counterpart to the manual /compact swap (chat_command rebuilds the
        # runner on result[:compact_into]).
        @session = lifecycle.active_session
        # Post-turn state, read by the subagent-completion path (task_tool) so a
        # force-summarized/truncated child is reported PARTIAL, not "completed".
        @last_stop_reason = lifecycle.last_stop_reason

        response
      end

      # How this runner's LAST turn terminated (Agent::Loop#stop_reason),
      # threaded up via Lifecycle. nil until a turn has run. Read by the `task`
      # tool after a subagent's #run! to distinguish a real completion from a
      # budget-/time-truncated partial.
      attr_reader :last_stop_reason

      # Pins the agent Definition this runner threads into every subsequent turn
      # (the sticky `/agent <name>` / Tab-cycle switch). Lifecycle reads
      # @agent_definition fresh on each #run!, so swapping it here takes effect
      # from the NEXT turn — the agent's system prompt and tool scope come along.
      # nil restores the default (build) persona. The reader feeds the CLI
      # status bar and a one-shot route that wants to restore it afterwards.
      attr_accessor :agent_definition

      # Runs ONE turn under +definition+ (a one-shot `/<name> <message>` route)
      # without disturbing the runner's sticky agent. The override is swapped in
      # for the single #run and restored in the ensure, so the next idle prompt
      # is back on whatever the user had pinned.
      def run_with_agent(definition, input, **)
        sticky = @agent_definition
        @agent_definition = definition
        run(input, **)
      ensure
        @agent_definition = sticky
      end

      # Flips the current turn's cancel token. Called from the UI thread when
      # the user hits Esc or a second Ctrl+C while the worker is mid-stream.
      # No-op when no turn is in flight.
      #
      # ONE Esc cancels whatever is in flight (#319): the FOREGROUND turn OR the
      # DETACHED post-turn polishing. Flipping both tokens is safe — a token is
      # one-shot and idle-when-untouched, so cancelling the not-running side is a
      # harmless no-op. The polishing worker stops between jobs and its aux
      # retry/backoff aborts mid-wait, leaving partial work in place.
      # +reason+ records WHY the turn was cancelled so the result label stays
      # truthful: :user (Esc/Ctrl+C, default) vs :external (SIGTERM/SIGHUP
      # teardown). Plumbed through to the CancelToken / Interrupted (#361b).
      def cancel!(reason: :user)
        @cancel_token&.cancel!(reason: reason)
        @polishing&.cancel!
      end

      # True while the detached post-turn polishing is still draining — drives
      # the non-blocking "polishing… (Esc to skip)" indicator the CLI shows
      # without owning the input.
      def polishing?
        @polishing&.running? || false
      end

      # Switches the LIVE model for this runner (the in-chat `/model <name>`).
      # Lifecycle builds the adapter per turn from
      # `@explicit_model_override || @session[:model]`, and the CLI always
      # passes a model_override at boot — so both fields must move for the
      # NEXT turn to actually hit the new model. The session hash is mutated
      # in place (statusbar and /status read it) and the persisted row is
      # updated so resume/--continue agree; an unpersisted lazy session gets
      # the new value via Repository#persist! on its first message instead.
      def switch_model!(model_id)
        @explicit_model_override = model_id
        @model_id = model_id
        @session[:model] = model_id
        @session[:provider] = @provider_override ||
                              LLM::ProviderResolver.resolve(model_id,
                                                            explicit_provider: @config.dig("model", "provider"))
        if @session_repo.persisted?(@session[:id])
          @session_repo.update(@session[:id], model: model_id, provider: @session[:provider])
        end
        model_id
      end

      # Aligns a RESUMED session's stored model with the model the adapter will
      # actually use this run (#model-resume). Lifecycle builds the adapter from
      # `@explicit_model_override || @session[:model]`, and the CLI ALWAYS passes
      # a boot override (explicit `-m`, else `model.default` from config) — so on
      # resume the override, NOT the model this session happened to last use, is
      # what generates. The session row, the footer/statusbar, the token-budget
      # context window and `/status` all read `session[:model]`, so without this
      # they showed the STALE pinned model (e.g. the old default) while the agent
      # was really running the new one: changing `model.default` looked ignored
      # even though generation honored it. Re-point the row to the effective
      # model so every surface tells the truth and a config change takes visible
      # effect. No-op when there is no explicit override (then the session model
      # IS what the adapter uses) or it already matches.
      def sync_resumed_session_model!(session)
        return unless @explicit_model_override
        return if session[:model] == @explicit_model_override

        session[:model]    = @explicit_model_override
        session[:provider] = @provider_override ||
                             LLM::ProviderResolver.resolve(@explicit_model_override,
                                                           explicit_provider: @config.dig("model", "provider"))
        return unless @session_repo.persisted?(session[:id])

        @session_repo.update(session[:id], model: session[:model], provider: session[:provider])
      end

      # Marks the current session ended (#100). Called from the CLI on a clean
      # REPL teardown (and best-effort on terminal close) so a session stops
      # showing as "active" forever and cleanup/list/--continue can tell a
      # finished session from a live one. Best-effort: a failure here must never
      # crash the exit path.
      # +handoff+ marks an IN-SESSION switch (the in-chat `/new`) where the REPL
      # immediately builds a fresh runner and stays interactive — as opposed to a
      # teardown/headless close where the process is about to exit. On a handoff
      # the in-flight-polishing wait is skipped — the still-running process's
      # worker drains the same process-global queue. The end-of-session review
      # fork itself branches on @interactive, not handoff (see
      # #flush_memory_on_session_end!): interactive enqueues detached, headless
      # runs inline so the row's facts are mined before the process dies.
      def end_session!(handoff: false)
        # Nothing to end for a session that was never persisted (the user opened
        # chat and left without sending a message, #144) — there's no row.
        return if @session.nil? || (@session[:persisted] == false && !@session_repo.persisted?(@session[:id]))

        # End-of-session review fork (#554): the turn-based review gate only
        # fires when the turn counter lands on the interval, so a short session
        # that ends before the interval — and never compacted — would never mine
        # its facts or distill its skills. This is the catch-all that runs the
        # warm-prefix review once on a clean close. Mirrors Hermes'
        # MemoryProvider#on_session_end. Best-effort: never breaks the exit.
        flush_memory_on_session_end!(handoff: handoff)

        @session_repo.end_session!(@session[:id])
      rescue StandardError
        nil
      ensure
        # Let any in-flight detached polishing settle (bounded) so a clean
        # teardown doesn't abandon a half-written extraction (#319). Best-effort:
        # the cursor re-feeds anything unfinished next session anyway. On a
        # handoff we DON'T wait — the prompt must stay instant and the new
        # runner's worker drains the same queue.
        @polishing&.wait(3) unless handoff
        # Release the per-session advisory lock (#543) so a subsequent
        # `--continue`/`--resume` of this id in another live process can claim it
        # cleanly. The kernel also drops the flock on process exit/crash, so this
        # is just the prompt clean-teardown release.
        @session_lock&.release
        @session_lock = nil
      end

      private

      # Run the end-of-session review fork (#554) — the SINGLE post-session
      # extraction path now that the structured aux-LLM memory extractor is gone.
      # BackgroundReviewJob mines durable memory AND distills skills off the
      # warm-prefix fork, so both surfaces are covered here. Gated on the same
      # config predicates the post-turn path uses and fully rescued so a memory
      # hiccup never crashes the exit path.
      #
      # INTERACTIVE (the in-chat `/new` handoff, or any REPL still alive): enqueue
      # the review DETACHED (drain_inline: false) so the prompt is never blocked —
      # the still-running polishing worker drains it off the process-global queue.
      # HEADLESS one-shot / API: the process is about to EXIT, so a detached job
      # would never drain; run the fork INLINE and synchronously before exit so
      # the session's durable facts are mined (and skills distilled) first.
      #
      # +handoff+ is retained for call-site compatibility but no longer branches:
      # the ONLY handoff caller (chat_command `/new`) is interactive, already
      # covered by the @interactive branch below.
      def flush_memory_on_session_end!(handoff: false) # rubocop:disable Lint/UnusedMethodArgument
        return unless @config.memory_auto_extract? || @config.skills_auto_distill?

        if @interactive
          Jobs::Queue.new.enqueue("BackgroundReviewJob", { session_id: @session[:id] },
                                  drain_inline: false)
        else
          Jobs::Handlers::BackgroundReviewJob.new.perform(session_id: @session[:id])
        end
      rescue StandardError
        nil
      end

      # True when +error+ is an AUTH/credential failure — a 401/unauthorized/
      # invalid-key signal, OR the "Authentication failed (…)" wrapper
      # ModelCallRunner#raise_with_auth_hint raises for a classified auth error.
      # Matches the SAME signal #friendly_error_message keys its auth branch on,
      # so the latched exit code and the displayed message never disagree.
      def auth_credential_error?(error)
        error.message.to_s.match?(/\b401\b|unauthorized|invalid[_ ]?api[_ ]?key|authentication failed/i)
      end

      # Translates upstream errors into actionable messages instead of
      # bare stack-trace fragments. (issue #16)
      #
      # The CLASSIFIER decides the category FIRST (#WHATIF): a provider 429 can
      # reach the streaming path mis-shaped as a 400 BadRequestError whose message
      # is ruby_llm's generic "Invalid request - please check your input" — the
      # original "rate_limit_error / Token Plan usage limit reached" survives only
      # in the response body, which the classifier (not the bare message) reads.
      # Keying the rate-limit / auth / model branches on the classified REASON
      # stops a quota error from reading like a prompt-validation 400 and sending
      # the dev to edit a fine prompt. We also LOG every surfaced error (the 429
      # was previously never written to rubino.log — a diagnosis gap).
      def friendly_error_message(error)
        msg    = error.message.to_s
        reason = safe_classify_reason(error)
        log_surfaced_error(error, reason)

        case reason
        when LLM::FailoverReason::RATE_LIMIT
          "rate limit / quota reached for the provider (#{msg}). Wait and retry, " \
          "or check your plan / billing. This is NOT a problem with your prompt."
        when LLM::FailoverReason::AUTH
          "authentication failed (#{msg}). Check your API key in ~/.rubino/.env " \
          "or run `rubino setup`."
        when LLM::FailoverReason::MODEL_NOT_FOUND
          "model '#{@model_id}' not available with the current provider/plan. " \
          "Check `model.default` in config.yml; details: #{msg}"
        when LLM::FailoverReason::TIMEOUT
          "network error reaching the LLM (#{msg}). Check connectivity and retry."
        else
          friendly_error_by_message(msg)
        end
      end

      # Message-shaped fallback for the residual cases the classifier leaves as
      # UNKNOWN/SERVER/FORMAT/etc. — preserves the original issue-#16 phrasings
      # for an error the classifier can't categorise from class/status/body.
      def friendly_error_by_message(msg)
        case msg
        when /\b401\b|unauthorized|invalid[_ ]?api[_ ]?key/i
          "authentication failed (#{msg}). Check your API key in ~/.rubino/.env " \
          "or run `rubino setup`."
        when /\b404\b|model.*not.*found|invalid[_ ]?model|unknown[_ ]?model/i
          "model '#{@model_id}' not available with the current provider/plan. " \
          "Check `model.default` in config.yml; details: #{msg}"
        when /\b(429|rate[_ ]?limit)\b/i
          "rate limit / quota reached for the provider (#{msg}). Wait and retry, " \
          "or check your plan / billing. This is NOT a problem with your prompt."
        when /\b(timeout|timed out|connection reset)\b/i
          "network error reaching the LLM (#{msg}). Check connectivity and retry."
        else
          "error: #{msg}"
        end
      end

      # Classify without ever letting a classifier hiccup mask the real error.
      def safe_classify_reason(error)
        LLM::ErrorClassifier.classify(error).reason
      rescue StandardError
        nil
      end

      # Record the surfaced model error to rubino.log — the streaming-path 429 was
      # previously never logged (only the distill job's error was), leaving no
      # trail to diagnose a quota outage. Best-effort; never raises into the UI.
      def log_surfaced_error(error, reason)
        Rubino.logger&.warn(event: "llm.error.surfaced", reason: reason,
                            error_class: error.class.name, error: error.message.to_s[0, 500])
      rescue StandardError
        nil
      end

      def load_or_create_session(session_id)
        if session_id
          # Support resume by title/first-prompt substring as well as ID
          session = @session_repo.find_by_id_or_title(session_id)
          unless session
            raise SessionError,
                  "Session not found: #{session_id}. " \
                  "Try `rubino sessions list`, or resume by id prefix."
          end

          # Owner-guard on EXPLICIT resume (#347): auto-resume already skips a
          # session a DIFFERENT live process is actively writing, but explicit
          # `--resume <id>` / `-s <id>` had NO guard — N processes could latch
          # the same "active" row and interleave writes into one malformed
          # transcript (user user user … assistant), poisoning the next resume's
          # history. When the target is live-owned by another process, fork a
          # fresh child that inherits the full history instead of stomping the
          # live session; the user keeps their context and the two writers never
          # interleave.
          # PER-SESSION ADVISORY LOCK (#543) acquired BEFORE the pid-CAS. The
          # CAS makes exactly one process *own* owner_pid, but it cannot close
          # the window BEFORE owner_pid is stamped: two concurrent `--continue`
          # both resolve the same latest session (owner_pid still nil for both
          # reads) and only serialise at the CAS — by which point the loser
          # forks a COPY of a transcript the winner is already writing,
          # duplicating/interleaving rows across the two sessions (#543 repro).
          # A real OS flock is atomic with no check-then-act window, so it
          # serialises the "open this session" decision itself. When we DON'T win
          # the lock, a different live process holds this session right now —
          # fork off a fresh child instead of stomping/forking its moving
          # transcript. The kernel drops the flock on exit/crash, so a SIGKILLed
          # owner never wedges the session.
          session_lock = Session::Lock.try_acquire(session[:id])
          return fork_busy_session(session) if session_lock.nil?

          # ATOMICALLY claim the row for THIS process (#390/residual #376).
          # The old code checked `owned_by_other_live_process?` then later
          # stamped owner_pid — a TOCTOU window where two concurrent
          # `--resume <id>` both read the same dead owner_pid, both passed the
          # check, and both stamped+wrote the live row (user,user … interleave).
          # claim_for_resume! folds the check and stamp into one compare-and-swap
          # (same idiom as Jobs::Queue#claim!): exactly one racer wins, the
          # loser gets false and forks a fresh child off the busy parent. Belt
          # and braces with the lock above: if we somehow hold the lock but lose
          # the CAS (a dead-owner row another process re-claimed), still fork.
          unless @session_repo.claim_for_resume!(session)
            session_lock.release
            return fork_busy_session(session)
          end

          # Hold the per-session lock for the rest of this process's life so a
          # later concurrent `--continue`/`--resume` of the SAME id forks rather
          # than interleaving. Retained on the runner so the fd isn't GC-closed
          # (which would silently drop the flock).
          @session_lock = session_lock

          # An existing row is already in the DB; mark it so the lazy-persist
          # path (#144) treats it as persisted and never re-inserts. We now own
          # owner_pid (stamped atomically above) so a later concurrent resume
          # sees us as the live owner and forks rather than interleaving.
          session[:persisted] = true
          session[:owner_pid] = Process.pid
          sync_resumed_session_model!(session)
          @ui.status("Resuming session: #{session[:id][0..7]}...") if @announce_session
          session
        else
          # Build an UNSAVED session: no row is written until the first user
          # message is committed (#144), so opening `chat` and leaving without
          # typing anything never pollutes `/sessions` with empty rows. The
          # record carries a real id so the whole turn pipeline works unchanged;
          # Lifecycle#persist_user_message flips it to a real row on demand.
          session = @session_repo.build(
            source: @session_source,
            model: @model_id,
            provider: @provider_override || LLM::ProviderResolver.resolve(@model_id)
          )
          @ui.status("New session: #{session[:id][0..7]}")
          session
        end
      end

      # Forks a child session off a parent another live process is still writing
      # (#347), copying the parent's full history so the explicit-resume user
      # keeps their context, while writing to a SEPARATE row so the two writers
      # never interleave into one malformed transcript. The child is owned by
      # THIS process. Mirrors the /branch copy (history + extraction watermark +
      # message_count sync) without a probe seed.
      def fork_busy_session(parent)
        store = @message_store
        child = @session_repo.create(
          source: "cli",
          model: parent[:model] || @model_id,
          provider: parent[:provider] || @provider_override,
          title: parent[:title],
          parent_session_id: parent[:id],
          cwd: parent[:cwd]
        )
        store.copy_into(child[:id], store.for_session(parent[:id]))
        store.seed_extraction_cursor(child[:id])
        @session_repo.update(child[:id], message_count: store.count(child[:id]))

        if @announce_session
          @ui.status(
            "Session #{parent[:id][0..7]} is in use by another rubino — " \
            "forked a copy: #{child[:id][0..7]}"
          )
        end
        child[:persisted] = true
        child
      end
    end
  end
end
