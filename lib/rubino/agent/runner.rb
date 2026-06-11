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
                     event_bus: nil, announce_session: true)
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
        @message_store = Session::Store.new
        @explicit_model_override = model_override
        @model_id = model_override || @config.model_default
        @provider_override = provider_override
        @max_turns = max_turns
        @ignore_rules = ignore_rules
        @agent_definition = agent_definition
        # Pre-instantiate so cancel! is meaningful between turns and during the
        # window between Signal.trap install and run() — a too-early Ctrl+C
        # used to land on a nil token and silently no-op, then the next run
        # started fresh and the user's cancel was lost.
        @cancel_token = Interaction::CancelToken.new
        @session = load_or_create_session(session_id)
      end

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
        @ui.error(friendly_error_message(e))
        nil
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
          max_tool_iterations: @max_turns
        )

        lifecycle.execute(input, image_paths: image_paths, input_queue: input_queue,
                                 paste_expansions: paste_expansions)
      end

      # Flips the current turn's cancel token. Called from the UI thread when
      # the user hits Esc or a second Ctrl+C while the worker is mid-stream.
      # No-op when no turn is in flight.
      def cancel!
        @cancel_token&.cancel!
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
                              LLM::ProviderResolver.resolve(model_id, explicit_provider: @config.model_provider)
        if @session_repo.persisted?(@session[:id])
          @session_repo.update(@session[:id], model: model_id, provider: @session[:provider])
        end
        model_id
      end

      # Marks the current session ended (#100). Called from the CLI on a clean
      # REPL teardown (and best-effort on terminal close) so a session stops
      # showing as "active" forever and cleanup/list/--continue can tell a
      # finished session from a live one. Best-effort: a failure here must never
      # crash the exit path.
      def end_session!
        # Nothing to end for a session that was never persisted (the user opened
        # chat and left without sending a message, #144) — there's no row.
        return if @session.nil? || (@session[:persisted] == false && !@session_repo.persisted?(@session[:id]))

        @session_repo.end_session!(@session[:id])
      rescue StandardError
        nil
      end

      private

      # Translates upstream errors into actionable messages instead of
      # bare stack-trace fragments. (issue #16)
      def friendly_error_message(error)
        msg = error.message.to_s
        case msg
        when /\b401\b|unauthorized|invalid[_ ]?api[_ ]?key/i
          "authentication failed (#{msg}). Check your API key in ~/.rubino/.env " \
          "or run `rubino setup`."
        when /\b404\b|model.*not.*found|invalid[_ ]?model|unknown[_ ]?model/i
          "model '#{@model_id}' not available with the current provider/plan. " \
          "Check `model.default` in config.yml; details: #{msg}"
        when /\b(429|rate[_ ]?limit)\b/i
          "rate-limited by the provider. Wait a moment and retry. Details: #{msg}"
        when /\b(timeout|timed out|connection reset)\b/i
          "network error reaching the LLM (#{msg}). Check connectivity and retry."
        else
          "error: #{msg}"
        end
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

          # An existing row is already in the DB; mark it so the lazy-persist
          # path (#144) treats it as persisted and never re-inserts.
          session[:persisted] = true
          @ui.status("Resuming session: #{session[:id][0..7]}...") if @announce_session
          session
        else
          # Build an UNSAVED session: no row is written until the first user
          # message is committed (#144), so opening `chat` and leaving without
          # typing anything never pollutes `/sessions` with empty rows. The
          # record carries a real id so the whole turn pipeline works unchanged;
          # Lifecycle#persist_user_message flips it to a real row on demand.
          session = @session_repo.build(
            source: "cli",
            model: @model_id,
            provider: @provider_override || LLM::ProviderResolver.resolve(@model_id)
          )
          @ui.status("New session: #{session[:id][0..7]}")
          session
        end
      end
    end
  end
end
