# frozen_string_literal: true

require "pastel"
require "io/console"
require "json"

module Rubino
  module CLI
    # Interactive and non-interactive chat session command.
    # Supported flags:
    #   -q/--query    one-shot non-interactive prompt
    #   -c/--continue resume most recent session
    #   -r/--resume   resume session by ID or title
    #   --provider    override provider
    #   --yolo        skip all approval prompts
    #   --max-turns   override max tool iterations
    #   --ignore-rules skip AGENTS.md and context files
    class ChatCommand
      include Rubino::UI::ProbeWaitIndicator

      # Window (seconds) for the Aider-style double-tap: a second Ctrl+C
      # within this of the first re-raises so the user can actually quit.
      DOUBLE_TAP_SECONDS = 2.0

      # Picker snippet length — enough to recognize the message at a glance.
      REWIND_SNIPPET_CHARS = 60

      # The confirm press must come after a deliberate beat (a blind mash
      # re-arms instead of confirming — the exact failure mode of #152 was
      # 2-5 quick presses while watching the stream) and before the arm goes
      # stale (the toast is long gone; a lone later press must re-confirm).
      YOLO_CONFIRM_MIN_SECONDS    = 0.3
      YOLO_CONFIRM_WINDOW_SECONDS = 5.0

      PROMPT_CARET = "❯"
      PROMPT_RAIL  = "▍"

      # Valid --output-format values (one-shot only). `text` is the default prose
      # path; `json`/`stream-json` are the machine-readable headless modes
      # (0.5.0, #312). The hyphen spelling is normalized to an underscore symbol.
      OUTPUT_FORMATS = %i[text json stream_json].freeze

      def initialize(options = {})
        @options = options
      end

      def execute
        query = opt(:query) || opt(:q)

        # Stdin fallback (#329c): when no prompt was given on the command line
        # (no -q/--query, no positional) AND stdin is a pipe/file (not a TTY),
        # read the prompt from stdin so `echo "..." | rubino prompt` and
        # `rubino prompt < file` work like other Unix tools. `prompt` with no
        # args supplies an EMPTY query (args.join == ""), so a blank query also
        # falls through to stdin here; only when stdin is also empty do we hit
        # the no-prompt guard below. A TTY stdin (bare interactive use) is left
        # untouched — nil query stays the interactive path.
        if query.nil? || query.strip.empty?
          piped = read_piped_prompt
          query = piped if piped && !piped.strip.empty?
        end

        # Empty/whitespace guard for the headless path (P2-H3): an empty
        # `-q`/`prompt ""` is truthy in Ruby, so it used to be dispatched
        # straight to the model — a wasted API turn and unpredictable
        # autonomous behaviour. Interactive mode already guards this
        # (`next if input.strip.empty?`); reject a blank one-shot query up
        # front with a clear stderr message + non-zero exit, BEFORE any setup,
        # model-config check, or runner is built. A nil query (bare `chat`)
        # is the interactive path and is left untouched.
        fail_arg!("no prompt provided") if query && query.strip.empty?

        ensure_setup!
        ensure_model_configured!

        if query
          run_oneshot(query)
        else
          run_interactive
        end
      rescue Rubino::AmbiguousSessionError, Rubino::SessionError => e
        # Render session-resolution errors as a clean stderr message + non-zero
        # exit, not a Ruby stack trace. AmbiguousSessionError's message
        # already includes the candidate list, so just print it.
        warn e.message
        exit(1)
      end

      private

      # --- Collaborators (#17): cohesive REPL concerns extracted into their own
      # classes (image inbox / session resolution + replay / idle card host);
      # ChatCommand orchestrates them around the turn loop. ---

      def image_inbox
        @image_inbox ||= Chat::ImageInbox.new
      end

      # The per-session paste store behind the file-backed paste pipeline:
      # large pastes collapse to "[Pasted text #N +M lines]" placeholders in
      # the composer and are expanded back to the full body (or to a
      # paste_N.txt read-tool pointer for oversized ones) in #run_turn, the
      # message-build seam. Shared across the per-turn composers, like
      # #pending_queued; /clear-images never touches it (different inbox).
      def paste_store
        @paste_store ||= Rubino::UI::PasteStore.new
      end

      def session_resolver
        @session_resolver ||= Chat::SessionResolver.new(@options)
      end

      def idle_cards
        @idle_cards ||= Chat::IdleCardHost.new
      end

      # Auto-opens the EXISTING approval / reply prompt for ONE pending subagent
      # request the human must act on, from the idle poll loop (#421). Delegates
      # to the SAME Handlers::Agents the /agents and /reply slash commands use, so
      # there is no second prompt or new verb — the affordance simply opens itself
      # at idle instead of waiting for the user to type a slash command. Returns
      # true when it presented a request (the poll loop repaints + re-checks),
      # false when nothing was pending. Best-effort: a hiccup in the auto-open
      # must never break the idle prompt, so it falls back to "nothing pending"
      # and the manual slash paths still work.
      def auto_resolve_pending_subagent_request(_runner = nil)
        agents_request_handler.auto_resolve_pending
      rescue StandardError => e
        # Resilience floor: a hiccup in the auto-open must never crash the idle
        # prompt, so we still fall back to "nothing pending". But a coding error
        # (NameError/NoMethodError) would fire on EVERY ~50ms tick and used to be
        # invisible forever — exactly how the #450 constant-scope bug shipped dead.
        # Log the swallowed error ONCE (deduped by class+message) at warn level so
        # a future programming error surfaces in dev/logs instead of hiding.
        warn_swallowed_auto_resolve_error(e)
        false
      end

      # Idle completion affordance (item 5): when a BACKGROUND subagent finishes
      # while the parent is sitting at the idle prompt, surface a non-blocking
      # one-liner — `✓ sa_… finished — /agents <id> for the result` — so the
      # parent stays free (no blocking, no polling, no narrating "waiting"). The
      # maintainer's decision: a background subagent runs async and the human is
      # NOTIFIED when it finishes, rather than the parent pretending to wait.
      #
      # Announced ONCE per entry (tracked in @announced_finished_subagents) so the
      # ~50ms poll doesn't repeat the line, and only for entries that finished
      # cleanly (:completed) — a :failed / :stopped child already gets its own
      # worker-surfaced notice, so re-announcing here would double-report. The
      # line commits ABOVE the pinned composer through the StdoutProxy already
      # swapped in for the idle read, exactly like a background-task note. Best
      # effort: a hiccup must never break the idle prompt.
      def surface_finished_subagents
        announced = (@announced_finished_subagents ||= {})
        Tools::BackgroundTasks.instance.list.each do |entry|
          next unless entry.status == :completed
          next if announced[entry.id]

          announced[entry.id] = true
          Rubino.ui.note("✓ #{entry.id} (#{entry.subagent}) finished — /agents #{entry.id} for the result")
        end
      rescue StandardError
        nil # the idle completion affordance is cosmetic — never break the prompt.
      end

      # True when the idle input buffer holds nothing the user is mid-typing, so
      # an autonomous background-subagent resume (#561) is safe to start without
      # pre-empting a half-written line. A composer-less path (piped / -q) has no
      # buffer to protect, so it's treated as empty. Best-effort: any hiccup
      # reading the buffer defers the resume (returns false) rather than risking
      # stomping a draft.
      def idle_buffer_empty?(composer)
        return true unless composer

        composer.buffer.to_s.strip.empty?
      rescue StandardError
        false
      end

      # Builds the SINGLE coalesced follow-up prompt that the autonomous resume
      # (#561) hands back at idle when one or more background subagents finished
      # after the parent's turn ended. All parked `[background-task]` completion
      # notices are joined into one turn (never one turn per child) and framed as
      # an instruction to act — fold in the results and deliver the combined
      # summary the parent owed the user. Mirrors Loop::NOTICES_PREAMBLE's intent
      # (notices are context to act on), shaped for a turn whose ONLY content is
      # the notices (there is no trailing user message to defer to here).
      def coalesced_resume_prompt(notices)
        "[background subagents finished — the work you delegated is done. " \
          "Fold in the results below and deliver the combined answer/summary " \
          "you owe the user; do not re-delegate or wait further.]\n\n" \
          "#{notices.join("\n\n")}"
      end

      # Emits a single warn for each distinct swallowed auto-resolve error so a
      # programming bug (NameError on every idle tick) is visible without spamming
      # the log once per 50ms poll. Transient runtime errors still degrade quietly.
      def warn_swallowed_auto_resolve_error(error)
        key = "#{error.class}:#{error.message}"
        @warned_auto_resolve_errors ||= {}
        return if @warned_auto_resolve_errors[key]

        @warned_auto_resolve_errors[key] = true
        Rubino.logger&.warn(
          event: "chat.auto_resolve_pending.swallowed",
          error: error.class.to_s, message: error.message
        )
      end

      def agents_request_handler
        # Fully qualified: lexically inside Rubino::CLI, a bare `Commands` resolves
        # to Rubino::CLI::Commands (the Thor class, which has no Handlers child),
        # raising NameError. Every other Commands::* ref in this file is already
        # fully qualified as Rubino::Commands::* — this one was the oversight (#450)
        # that left the auto-open dead because the NameError was swallowed below.
        @agents_request_handler ||= Rubino::Commands::Handlers::Agents.new(ui: Rubino.ui)
      end

      def bang_shell
        @bang_shell ||= Chat::BangShell.new
      end

      # --- One-shot mode ---

      # Resolves the effective one-shot output format from --output-format and
      # the --json alias. --json wins (it's the explicit shorthand). An unknown
      # value fails fast with a clear stderr message + non-zero exit BEFORE any
      # model work, so a typo never silently degrades to prose. Default :text.
      def output_format
        # Validate an EXPLICIT --output-format value FIRST, even when --json is
        # also passed (F10). Returning :json early on --json used to skip this
        # check, so `--json --output-format xml` silently ignored the bogus `xml`
        # and exited 0 — a typo that should have been rejected. An invalid value
        # is always an error; --json then only aliases a *valid-or-absent* format.
        raw = (opt(:output_format) || opt(:"output-format")).to_s.strip
        unless raw.empty?
          fmt = raw.tr("-", "_").to_sym
          unless OUTPUT_FORMATS.include?(fmt)
            fail_arg!("invalid --output-format '#{raw}' (expected: text, json, stream-json)", exit_code: 2)
          end
        end

        return :json if opt(:json) == true
        return :text if raw.empty?

        fmt
      end

      # True for the machine-readable headless modes, where ALL JSON goes to
      # stdout and ALL diagnostics to stderr (markdown rendering suppressed).
      def json_mode?(fmt = output_format)
        fmt != :text
      end

      # Whether the user ASKED for a machine-readable mode, decided WITHOUT going
      # through #output_format (which exits on an invalid value — and the invalid
      # value itself is one of the arg errors we want to report as JSON). Used by
      # #fail_arg! so a bad CLI argument under --output-format json|stream-json
      # still emits a JSON error envelope on stdout, not a bare plain-text line.
      def json_requested?
        return true if opt(:json) == true

        raw = (opt(:output_format) || opt(:"output-format")).to_s.strip.tr("-", "_")
        %w[json stream_json].include?(raw)
      end

      # Surface a CLI ARGUMENT error (empty prompt, invalid --output-format)
      # consistently with the chosen output mode (#327): under a json/stream-json
      # request, emit a {type:"result", is_error:true, …} envelope on stdout so
      # automation can parse the failure; otherwise the plain "rubino: <msg>" on
      # stderr. Always non-zero exit. No run/model/recorder exists at this point,
      # so the envelope carries zeroed usage and a nil session.
      def fail_arg!(message, exit_code: 1)
        if json_requested?
          emit_json(Output::ResultSerializer.arg_error(message: message))
        else
          warn "rubino: #{message}"
        end
        exit(exit_code)
      end

      # Shared one-shot preamble for the text and JSON paths: resolve @image
      # tokens + --image flags into the native vision slot, build the headless
      # runner, surface the resume-forked / resuming-compacted notices, and
      # attach the per-run usage recorder (the SAME summed-usage seam both paths
      # persist). Returns the shared pieces by position so each caller layers its
      # own bits (text: model echo + activity trace + skill capture; JSON: the
      # system_init frame + transcript baseline) around it.
      def setup_oneshot(query, ui:, announce_session: true)
        text, image_paths = Chat::ImageInbox.resolve_oneshot(query, opt(:image))
        requested_session_id = session_resolver.resolve_session_id
        runner = build_runner(session_id: requested_session_id, ui: ui,
                              announce_session: announce_session)
        warn_if_resume_forked(requested_session_id, runner)
        note_if_resuming_compacted_parent(runner)
        recorder = Output::TurnRecorder.new.attach!
        [runner, text, image_paths, recorder]
      end

      def run_oneshot(query)
        resolve_yolo!
        # Clear the cross-adapter fail-closed latch (F1-subagents) so a reused
        # embedder/test process never inherits a block from a prior run.
        Output::HeadlessBlockLatch.reset!

        fmt = output_format
        return run_oneshot_json(query, fmt) if json_mode?(fmt)

        # Structured JSON log lines (llm.retry & friends) must never contaminate
        # the one-shot stdout (#99): `answer=$(rubino prompt ...)` pipes stdout,
        # so a warn event would interleave JSON noise with the answer. Route the
        # logger to stderr for the whole one-shot run — the diagnostic twin of
        # the interactive REPL's redirect-to-file (#125). Restored in the ensure
        # so embedders/tests sharing the memoized logger are unaffected.
        prev_log_io = redirect_logger_to_stderr

        # Surface the resolved model (and any unknown-id warning) before the
        # answer (#142). In one-shot mode there is no chat header, so without
        # this a typo'd `-m` silently runs the wrong/forced-through model with
        # zero feedback. Echo only when the user passed an explicit override so
        # we don't add noise to the default-model happy path.
        announce_resolved_model

        # Seed --add-dir roots; one-shot mode is non-interactive so the trust
        # prompt is skipped (an untrusted dir simply runs in restricted mode).
        setup_workspace_and_trust!(Rubino.ui, interactive: false)

        # Default-on per-tool ACTIVITY TRACE for the one-shot TEXT path (#418
        # follow-up): a plain UI::Null swallows every tool event, so a scripted
        # `rubino prompt` showed only the final answer with no window onto what
        # files were edited / commands run. UI::HeadlessTrace adds ONE concise
        # line per tool completion ON STDERR (`· edit foo.rb`), keeping STDOUT a
        # clean answer-only stream by construction. `--quiet`/-Q selects the
        # silent machine path (plain UI::Null); `--verbose`/-v widens the hint.
        # Mirrors the Codex/gemini-cli/Hermes stderr-trace norm (Hermes' `-q`
        # default / `-Q` quiet). json/stream-json never reach here (run_oneshot_json).
        headless_ui = if quiet?
                        UI::Null.new
                      else
                        UI::HeadlessTrace.new(verbose: verbose?)
                      end
        # Shared preamble: resolve @image/--image attachments, build the runner,
        # surface the resume notices, attach the usage recorder (#382). The runner
        # is run! (not run) below so a model/credential failure PROPAGATES instead
        # of being swallowed into a nil and printed as an empty line with exit 0
        # (#93): a no-key user would otherwise see ~80s of silent retries then an
        # empty prompt and a success exit.
        runner, text, image_paths, recorder = setup_oneshot(query, ui: headless_ui)

        # Capture skills distilled during this turn (#369b). SKILL_CREATED is
        # emitted by an inline skill(create) call AND by the post-turn distill
        # job (drained below) on the process-global bus the headless runner +
        # polishing worker share — but the Null UI swallows it, so the user
        # never learns distillation produced a skill. Collect the names here and
        # surface them to STDERR after the answer (mirroring the #372 routing:
        # post-turn notices stay off the clean stdout answer).
        created_skills = subscribe_created_skills

        announce_attachment_upload(image_paths)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # SIGINT in a one-shot run (#335a): without a trap, Ctrl+C lands as a
        # bare Interrupt inside net/protocol's blocking socket read and escapes
        # as a 60-line uncaught backtrace, exit 130. Install a cooperative trap
        # that flips the runner's cancel token so the in-flight LLM stream is
        # cancelled at the next chunk checkpoint (the same mechanism the
        # interactive path uses); the Interrupted that then propagates is caught
        # below and turned into a clean, truthful "interrupted" exit. A second
        # Ctrl+C (or one that races in before the first chunk, deep in the
        # blocking read) still raises a bare Interrupt — also caught below.
        response = with_oneshot_int_trap(runner) do
          # Bind the headless flag for the duration of the turn so TaskTool runs
          # `task` subagents FOREGROUND in one-shot (#380) — there is no
          # IdleCardHost to fold a background child's result back in and the
          # process exits the instant the answer is ready, so a background
          # fan-out would be silently dropped.
          Rubino.with_headless { runner.run!(text, image_paths: image_paths) }
        end

        # Write the per-run usage row (#382) before printing/exiting.
        persist_oneshot_run!(runner, text, recorder)

        print_oneshot_answer(response.to_s)
        $stdout.flush

        # Drain the detached post-turn polishing before exit (#358). In headless
        # one-shot mode there is no live REPL to pick the queued post-turn rows
        # up at a future enqueue, and the process exits the moment run! returns —
        # so memory-extract / skill-distill / summarize would pile up `queued`
        # and NEVER run (memory_facts stayed 0, the queue grew unbounded across
        # headless runs). Join the worker the turn just kicked off so the
        # extraction completes at least once per headless session.
        drain_post_turn_jobs!(runner, headless_ui)

        # Now that inline + post-turn distillation has run, surface any new skill
        # to stderr (#369b) — concise, off the stdout answer.
        announce_created_skills(created_skills)

        # Fire the turn-finished attention seam for headless runs (#215). A
        # scripted `rubino prompt`/-q run never goes through UI::CLI#turn_finished
        # (it uses UI::Null), so the documented notifications.command hook —
        # exactly what automation wants to ping a human on completion — never
        # fired. Drive the same notifier here: the BELL self-suppresses into a
        # pipe (bell_sink is nil off a TTY), so only the detached command hook
        # actually does anything headless, which is the intent. Best-effort: a
        # notification must never fail the run or contaminate the piped answer.
        notify_oneshot_finished(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at)

        # Fail-closed exit (#260): if any tool was BLOCKED because it needed
        # approval in this headless run (a write/edit/non-allowlisted shell with
        # no --yolo), echo the single-line block notice(s) to stderr (the Null
        # UI otherwise swallows them) and exit NON-ZERO so CI/automation/scripts
        # detect that the action was refused — never silently treat a skipped
        # command as success. The answer on stdout stays clean. --yolo opts back
        # into auto-exec and never reaches this branch.
        # End the session on one-shot completion (ONESHOT-ACTIVE) so it doesn't
        # linger as status=active forever and confuse auto-resume / `sessions
        # list` — the interactive REPL ends its session on teardown, the headless
        # path skipped it entirely. Best-effort and bounded (end_session! rescues
        # internally), and done BEFORE the fail-closed exits below so even a
        # blocked/truncated run finalizes its row.
        runner.end_session!

        # Fail-closed exit (#260): if any tool was BLOCKED because it needed
        # approval in this headless run — directly OR inside a `task` subagent
        # (F1-subagents, via the process-global latch) — echo the single-line
        # block notice(s) to stderr (the Null UI otherwise swallows them) and exit
        # NON-ZERO so CI/automation/scripts detect that the action was refused.
        # The answer on stdout stays clean. --yolo opts back into auto-exec.
        if headless_ui.approval_blocked? || Output::HeadlessBlockLatch.blocked?
          block_messages_for_exit(headless_ui).each { |m| warn m }
          exit(2)
        end

        # Budget-truncated run (STRUCT-F1): the loop hit --max-turns and forced a
        # "here's what I got to" summary rather than the model finishing. That is
        # NOT success — surface it to stderr and exit non-zero so automation sees
        # the truncation, instead of the old silent exit 0. The forced summary is
        # already on stdout (the truthful partial answer). Claude Code aligns:
        # turn-limit ⇒ error + non-zero exit.
        if Output::ResultSerializer.budget_exhausted?(recorder.stop_reason)
          warn "rubino: turn budget exhausted (--max-turns); run truncated"
          exit(1)
        end
      # A user interrupt (#335a) — the cooperative Rubino::Interrupted, or a bare
      # Interrupt/SIGINT that landed deep in a blocking read before the next
      # chunk checkpoint — exits cleanly with the conventional 130, NOT a raw
      # 60-line backtrace. The partial the model produced is already persisted by
      # the Loop (marked interrupted), so the run stays truthful & resumable.
      # Interrupt is listed for doc value though SignalException already covers it.
      rescue Rubino::Interrupted, Interrupt, SignalException => e # rubocop:disable Lint/ShadowedException
        # Print the partial the model streamed before the interrupt (#349). The
        # Loop already persisted it (marked interrupted:true), but run! raises out
        # before #print_oneshot_answer — so without this, `rubino -q` on SIGINT
        # produced ZERO bytes on stdout even though the answer-so-far IS stored.
        # `answer=$(rubino -q …)` then captured nothing on Ctrl+C. Emit whatever
        # was produced so the partial reaches the caller before the 130 exit.
        partial = oneshot_interrupted_partial(runner)
        unless partial.to_s.empty?
          print_oneshot_answer(partial)
          $stdout.flush
        end
        # Label truthfully (#361b, #378): only an EXTERNAL teardown
        # (SIGTERM/SIGHUP, surfaced as a cooperative Rubino::Interrupted with
        # reason :external) is "by external signal". A bare Interrupt/SIGINT — the
        # user pressing Ctrl-C, which is NOT a Rubino::Interrupted — is a USER
        # interrupt, not external; the prior `: true` default mislabeled it.
        external = oneshot_external_interrupt?(e)
        warn "rubino: #{external ? "interrupted by external signal" : "interrupted"}"
        exit(130)
      rescue SystemExit
        raise
      rescue Exception => e # rubocop:disable Lint/RescueException
        warn "rubino: #{e.message}"
        exit(1)
      ensure
        # ONESHOT-ACTIVE on the FAILURE path (item 6): a TERMINAL exception
        # (provider unreachable / unknown model / any uncaught error) raises out
        # AFTER the session row was created but BEFORE the success-path
        # end_session! above, so the row used to linger status=active with a
        # stale owner_pid until a future `sessions list` reaped it. Finalize it
        # to `ended` here in the ensure — the single chokepoint every exit path
        # (success, interrupt, error, SystemExit re-raise) runs through — so the
        # row is correct IMMEDIATELY, not eventually. Idempotent and best-effort
        # (end_session! rescues internally, no-ops an unpersisted/already-ended
        # row), so re-running it after the success-path call is harmless.
        finalize_oneshot_session!(runner)
        recorder&.detach!
        restore_logger(prev_log_io)
      end

      # Best-effort finalize of the one-shot session row to `ended`, called from
      # the ensure of BOTH one-shot paths (text + json) so a terminal exception
      # never leaves a status=active row behind (item 6). `runner` may be nil if
      # the failure happened before it was built (e.g. in setup); guard for that.
      # end_session! is itself fully rescued, so this can never break the exit.
      def finalize_oneshot_session!(runner)
        runner&.end_session!
      rescue StandardError
        nil
      end

      # Machine-readable headless one-shot (0.5.0, #312). Emits Claude-Code-aligned
      # JSON for CI/automation instead of prose:
      #
      #   :json        — a SINGLE {type:"result", …} object on stdout at completion.
      #   :stream_json — JSONL: {type:"system",subtype:"init",…} then one
      #                  {type:"assistant"|"user", message:{…}} per persisted step
      #                  then the SAME final {type:"result", …}.
      #
      # Discipline: ALL JSON goes to stdout; ALL logs/diagnostics/errors go to
      # stderr (the logger is already pinned to stderr below, and the Null UI
      # suppresses markdown), so NOTHING but JSON lands on stdout. The existing
      # fail-closed / exit-code contract is preserved: a blocked tool ⇒ the json
      # still emits with is_error:true and a non-zero exit; a failed run ⇒ an
      # error result + exit 1.
      def run_oneshot_json(query, fmt)
        prev_log_io = redirect_logger_to_stderr
        # Clear the cross-adapter fail-closed latch (F1-subagents), same as text.
        Output::HeadlessBlockLatch.reset!
        # The unknown-model warning still helps automation debug a typo — it goes
        # to stderr, so the stdout JSON contract is untouched.
        warn_unknown_model if model_override_given?
        setup_workspace_and_trust!(Rubino.ui, interactive: false)

        # Shared preamble (same seam the text path uses), but with a silent Null
        # UI and announce_session:false so nothing prints to the stdout JSON
        # contract.
        headless_ui = UI::Null.new
        runner, text, image_paths, recorder =
          setup_oneshot(query, ui: headless_ui, announce_session: false)
        store = ::Rubino::Session::Store.new
        # Snapshot the transcript length so stream-json replays only THIS turn's
        # newly-persisted messages (the user prompt, assistant/tool steps).
        baseline = store.for_session(runner.session[:id]).length

        if fmt == :stream_json
          emit_json(Output::ResultSerializer.system_init(
                      session: runner.session, model: model_name, tools: turn_tool_names(runner)
                    ))
        end

        announce_attachment_upload(image_paths)
        started_at = monotonic_now
        # Same cooperative SIGINT trap as the text path (#335a): flip the cancel
        # token so the in-flight stream is cancelled at the next checkpoint
        # rather than letting a bare Interrupt escape as a raw backtrace.
        response = with_oneshot_int_trap(runner) do
          # Force `task` subagents foreground in one-shot (#380), same as the text
          # path — no IdleCardHost here either to fold a background result back in.
          Rubino.with_headless { runner.run!(text, image_paths: image_paths) }
        end
        duration_ms = ((monotonic_now - started_at) * 1000).round

        # Persist the per-run usage row (#382) from the already-attached recorder,
        # same as the text path.
        persist_oneshot_run!(runner, text, recorder)

        # Drain the detached post-turn polishing before exit (#358), same as the
        # text path: a headless JSON/stream-json run also exits the instant run!
        # returns, so without joining the worker the post-turn jobs never run.
        drain_post_turn_jobs!(runner, headless_ui)

        if fmt == :stream_json
          new_messages = store.for_session(runner.session[:id]).drop(baseline)
          Output::ResultSerializer.message_frames(new_messages).each { |f| emit_json(f) }
        end

        notify_oneshot_finished(duration_ms / 1000.0)

        # End the session on one-shot completion (ONESHOT-ACTIVE), same as text:
        # leave no status=active row behind. Before the fail-closed exits so even
        # a blocked/truncated run finalizes its row. Best-effort/bounded.
        runner.end_session!

        # Fail-closed (#260) preserved in JSON form: a blocked tool — directly OR
        # inside a `task` subagent (F1-subagents, via the latch) — still emits a
        # complete result, flagged is_error with exit 2 so CI fails loudly.
        if headless_ui.approval_blocked? || Output::HeadlessBlockLatch.blocked?
          block_msgs = block_messages_for_exit(headless_ui)
          block_msgs.each { |m| warn m }
          emit_json(Output::ResultSerializer.error_result(
                      recorder: recorder, session: runner.session, duration_ms: duration_ms,
                      model: model_name,
                      error: { subtype: "error_tool_blocked", type: "tool_blocked",
                               result_text: response.to_s,
                               message: block_msgs.join("; ") }
                    ))
          exit(2)
        end

        # Budget-truncated run (STRUCT-F1): the loop hit --max-turns and forced a
        # "here's what I got to" summary rather than finishing. That is NOT a
        # success — emit an error envelope (is_error:true, subtype error_max_turns)
        # and exit non-zero so CI/automation sees the truncation, instead of the
        # old subtype:"success"/exit-0. The forced summary text is still carried in
        # `result` so the caller keeps the partial answer. Claude Code aligns:
        # turn-limit ⇒ is_error:true + non-zero exit.
        if Output::ResultSerializer.budget_exhausted?(recorder.stop_reason)
          emit_json(Output::ResultSerializer.error_result(
                      recorder: recorder, session: runner.session, duration_ms: duration_ms,
                      model: model_name,
                      error: { subtype: "error_max_turns", type: "max_turns_exceeded",
                               result_text: response.to_s,
                               message: "turn budget exhausted (--max-turns); run truncated" }
                    ))
          exit(1)
        end

        emit_json(Output::ResultSerializer.result(
                    recorder: recorder, final_text: response.to_s, session: runner.session,
                    duration_ms: duration_ms, model: model_name
                  ))
      # A user interrupt (#335a) still emits a well-formed, parseable result
      # object on stdout (flagged interrupted) so automation never sees a raw
      # backtrace, then exits with the conventional 130. The Loop already
      # persisted the partial (marked interrupted), so the session is truthful.
      # Interrupt is listed for doc value though SignalException already covers it.
      rescue Rubino::Interrupted, Interrupt, SignalException => e # rubocop:disable Lint/ShadowedException
        # Label truthfully (#361b, #378): only an EXTERNAL teardown
        # (SIGTERM/SIGHUP, a cooperative Rubino::Interrupted with reason :external)
        # is "by external signal". A bare Interrupt/SIGINT — the user pressing
        # Ctrl-C, NOT a Rubino::Interrupted — is a USER interrupt; the prior
        # `: true` default mislabeled it as external.
        external = oneshot_external_interrupt?(e)
        message = external ? "interrupted by external signal" : "interrupted by user"
        subtype = external ? "error_external_signal" : "error_interrupted"
        warn "rubino: #{message}"
        # Carry the persisted partial into the result envelope's `result` field
        # (#349) so automation parsing the interrupted run still sees the
        # answer-so-far, not an empty string — the JSON twin of printing the
        # partial on the text path above.
        emit_json(Output::ResultSerializer.error_result(
                    recorder: recorder, session: runner&.session,
                    duration_ms: started_at ? ((monotonic_now - started_at) * 1000).round : 0,
                    model: model_name,
                    error: { message: message, type: "Rubino::Interrupted",
                             subtype: subtype,
                             result_text: oneshot_interrupted_partial(runner) }
                  ))
        exit(130)
      rescue SystemExit
        raise
      rescue Exception => e # rubocop:disable Lint/RescueException
        # A failed run still produces a well-formed result object on stdout (with
        # the error on a top-level error block) so automation can parse the
        # failure — the message ALSO goes to stderr for human logs. Exit 1.
        warn "rubino: #{e.message}"
        emit_json(Output::ResultSerializer.error_result(
                    recorder: recorder, session: runner&.session,
                    duration_ms: started_at ? ((monotonic_now - started_at) * 1000).round : 0,
                    model: model_name,
                    error: { message: e.message, type: e.class.name,
                             subtype: "error_during_execution" }
                  ))
        exit(1)
      ensure
        # ONESHOT-ACTIVE on the JSON failure path (item 6): same as the text path
        # — a terminal exception must finalize the session row to `ended` here so
        # it never lingers status=active with a stale owner_pid. Idempotent and
        # best-effort.
        finalize_oneshot_session!(runner)
        recorder&.detach!
        restore_logger(prev_log_io)
      end

      # The fail-closed block notices to echo on a headless exit (F1-subagents):
      # the parent adapter's own blocks PLUS any a `task` subagent latched in the
      # process-global HeadlessBlockLatch. Deduped/ordered (parent first), never
      # empty when either source flagged a block, so the stderr is always
      # informative even when only a subagent was refused.
      def block_messages_for_exit(headless_ui)
        msgs = headless_ui.blocked_messages + Output::HeadlessBlockLatch.messages
        msgs.uniq
      end

      # Writes one JSON object as a single line to the REAL stdout and flushes.
      # All headless JSON goes through here so the stdout=JSON discipline has one
      # chokepoint. JSON.generate emits no embedded newlines, so json mode is one
      # line and stream-json is valid JSONL (one object per line).
      def emit_json(object)
        $stdout.puts(JSON.generate(object))
        $stdout.flush
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # The tool names offered this turn, for stream-json's system/init frame.
      # Best-effort: a registry hiccup must never break the headless run — fall
      # back to an empty list so the frame still emits.
      def turn_tool_names(_runner)
        Rubino::Tools::Registry.instance.enabled_tools.map { |t| t.respond_to?(:name) ? t.name.to_s : t.to_s }
      rescue StandardError
        []
      end

      # One deterministic status line before a request that carries attachments
      # (#101): a multi-MB upload can stall for tens of seconds with zero
      # feedback in one-shot mode. Goes to stderr so the piped stdout answer
      # stays clean.
      def announce_attachment_upload(image_paths)
        return if image_paths.empty?

        mb    = (image_paths.sum { |p| File.size?(p).to_i } / 1_048_576.0).round(1)
        label = image_paths.size == 1 ? "image" : "#{image_paths.size} images"
        warn "sending #{label} (#{mb} MB)…"
      end

      # Prints the one-shot answer. On a real TTY the answer goes through the
      # SAME markdown pipeline interactive chat uses (UI::CLI#assistant_text →
      # MarkdownRenderer: styled headings/bold/code, width-fit tables, wrapping)
      # so `prompt`/-q doesn't dump literal `**`/`|---|` markdown at a human
      # (#69). When stdout is NOT a TTY the raw text is kept byte-for-byte —
      # `answer=$(rubino prompt ...)` and downstream tools want plain text, and
      # diagnostics already route to stderr (#99) so the pipe stays clean.
      def print_oneshot_answer(text)
        if $stdout.respond_to?(:tty?) && $stdout.tty?
          UI::CLI.new.assistant_text(text)
        else
          $stdout.puts text
        end
      end

      # Drains the post-turn polishing jobs before a headless one-shot exits
      # (#358). The interactive REPL drains them on the detached worker and picks
      # up stragglers at the next idle prompt / on #end_session!'s bounded wait —
      # but a one-shot process exits the moment run! returns, with no future
      # enqueue and no REPL, so the memory-extract / skill-distill rows the turn
      # queued would sit `queued` forever (memory_facts stayed 0; the queue grew
      # unbounded across runs).
      #
      # First JOIN the detached worker the turn kicked off so its in-flight
      # extraction finishes. Then sweep any rows still `queued` synchronously via
      # the inline reaper — a belt-and-braces drain that also recovers rows a
      # PRIOR interrupted headless run orphaned, so a stuck queue self-heals on
      # the next headless turn. Best-effort: a drain detail must never fail the
      # run or contaminate stdout.
      # Subscribe to SKILL_CREATED on the process-global bus and accumulate the
      # distilled skill names (#369b). Thread-safe: the distill job emits from
      # the polishing worker thread during the drain, so the collection is
      # guarded by a mutex. Returns the shared array the listener appends to.
      def subscribe_created_skills
        names = []
        lock  = Mutex.new
        Rubino.event_bus.on(Rubino::Interaction::Events::SKILL_CREATED) do |payload|
          name = payload[:name].to_s
          lock.synchronize { names << name } unless name.empty?
        end
        names
      rescue StandardError
        []
      end

      # One concise stderr line per skill distilled this turn (#369b), so a
      # scripted `rubino -q` user learns a skill was created without the notice
      # polluting the clean stdout answer (the #372 routing discipline).
      def announce_created_skills(names)
        return if names.nil? || names.empty?

        names.uniq.each { |name| warn "rubino: distilled new skill: #{name}" }
      rescue StandardError
        nil
      end

      def drain_post_turn_jobs!(runner, headless_ui = nil)
        runner.polishing.wait if runner.respond_to?(:polishing) && runner.polishing
        # Route the inline orphan-reaper through the headless (Null) UI (#372).
        # The detached polishing worker already runs under the runner's Null UI,
        # but #reap_inline_orphans runs on THIS main thread with no UI binding,
        # so a job it sweeps (e.g. ExtractMemoryJob#confirm → Rubino.ui.note) would
        # resolve to the GLOBAL stdout-backed UI::CLI and leak its
        # "✓ saved to memory …" banner onto stdout — polluting
        # `answer=$(rubino prompt …)`. Bind the Null UI so headless stdout stays
        # exactly the model answer.
        reap = -> { Jobs::Queue.new.reap_inline_orphans }
        headless_ui ? Rubino.with_ui(headless_ui, &reap) : reap.call
      rescue StandardError => e
        Rubino.logger.warn(event: "oneshot.drain_failed", error: e.class.name, message: e.message)
        nil
      end

      # True when the interrupt that unwound the one-shot run was an EXTERNAL
      # teardown (SIGTERM/SIGHUP), not a user Ctrl-C (#378). Only our cooperative
      # Rubino::Interrupted carries a reason — the session-end traps flip it to
      # :external on SIGTERM/SIGHUP (#361b). A bare Interrupt/SignalException is a
      # user SIGINT, so it is NOT external (the prior code defaulted those to
      # external and mislabeled Ctrl-C as "interrupted by external signal").
      def oneshot_external_interrupt?(error)
        error.is_a?(Rubino::Interrupted) && error.reason == :external
      end

      # Persists one `runs` row for a completed headless turn (#382) with the real
      # summed token counts from the turn's recorder. Best-effort: a persistence
      # detail must never fail the run or contaminate the piped answer — a missing
      # runs row is a telemetry gap, not a user-facing failure.
      def persist_oneshot_run!(runner, input_text, recorder)
        return unless runner&.session && recorder

        repo = Run::Repository.new
        run = repo.create(
          session_id: runner.session[:id], input_text: input_text.to_s,
          model: model_name, provider: opt(:provider)
        )
        repo.mark_completed!(run[:id],
                             tokens_input: recorder.input_tokens,
                             tokens_output: recorder.output_tokens)
      rescue StandardError => e
        Rubino.logger.warn(event: "oneshot.run_persist_failed", error: e.class.name, message: e.message)
        nil
      end

      # The partial answer the Loop persisted when a one-shot turn was interrupted
      # (#349), or "" when none. On SIGINT, run! raises before the answer is
      # printed, but the Loop already stored what streamed so far as the last
      # assistant message flagged metadata[:interrupted] — read it back so the
      # interrupt handler can surface it (stdout on the text path, the result
      # envelope on the JSON path). Best-effort: never let a lookup error mask the
      # interrupt — return "" so the run still exits 130 cleanly.
      def oneshot_interrupted_partial(runner)
        return "" unless runner&.session

        messages = ::Rubino::Session::Store.new.for_session(runner.session[:id])
        last = messages.reverse.find do |m|
          m.role == "assistant" && m.metadata.is_a?(Hash) && m.metadata[:interrupted]
        end
        last&.content.to_s
      rescue StandardError
        ""
      end

      # Drives the turn-finished attention notifier after a one-shot run (#215),
      # so the documented notifications.command hook fires for headless/scripted
      # `rubino prompt` / -q completions too — the seam automation uses to ping a
      # human. The notifier's own min_turn_seconds gate still applies (quick runs
      # stay silent) and the bell self-suppresses into a pipe, so off a TTY only
      # the detached command hook runs. Wholly best-effort: a notification detail
      # must never fail the run.
      def notify_oneshot_finished(elapsed)
        UI::Notifier.new.turn_finished(elapsed)
      rescue StandardError
        nil
      end

      # Routes the structured logger to stderr for the one-shot run (#99).
      # Returns the previous sink IO to restore on exit; nil (no-op) on failure —
      # a logging-destination detail must never break the run.
      def redirect_logger_to_stderr
        Rubino.logger.reopen($stderr)
      rescue StandardError
        nil
      end

      # --- Interactive mode ---
      #
      # One path for TTY and non-TTY: inline streaming to stdout.
      # No fullscreen TUI. Native terminal scroll, copy, and shell
      # history all keep working because we never leave the main screen.

      def run_interactive
        resolve_yolo!

        ui = Rubino.ui

        # Validate an EXPLICIT --resume/--session id BEFORE the boot banner
        # (#resume-banner-order): a bad id used to print the rubino/workspace/
        # branch/model banner on stdout and THEN the "Session not found" error on
        # stderr — making a failed resume look like a session was starting. Fail
        # cleanly first (stderr + exit 1, via the SessionError rescue in #chat)
        # so no misleading banner is emitted. The happy path (valid id) is
        # untouched: build_runner below does the authoritative resume.
        validate_explicit_resume!

        # Capture git context before creating runner (session not yet available)
        git = git_context

        ui.blank_line
        ui.info("rubino")
        ui.status("workspace  #{collapse_home(Dir.pwd)}")
        if git
          dirty_mark = git[:dirty] ? " *" : ""
          ui.status("branch     #{git[:branch]}#{dirty_mark} @ #{git[:sha]}")
        end
        ui.status("model      #{model_name}")
        warn_unknown_model if model_override_given?
        # Update-available notice (interactive only): one dim line, sourced
        # purely from the local cache so it never slows boot. The network
        # refresh below is detached/rescued and only freshens the cache for the
        # NEXT boot. No-ops entirely until rubino-agent is published.
        note = Rubino::UpdateCheck.notice_from_cache
        ui.status(note) if note
        Rubino::UpdateCheck.refresh_async_if_stale
        ui.blank_line

        # Seed --add-dir roots and run the folder-trust gate before any turn
        # assembles a system prompt that could pull in an untrusted dir's
        # AGENTS.md / skills.
        setup_workspace_and_trust!(ui, interactive: true)

        runner = build_runner(session_id: session_resolver.resolve_session_id(auto_resume: true), ui: ui)

        # Scope tier-2 paste files under the CURRENT session's artifacts dir
        # (<home>/sessions/<id>/paste_N.txt). The closure reads the local
        # `runner` at write time, so /new //sessions //branch — which reassign
        # it — re-scope the files without re-wiring.
        paste_store.session_source = -> { runner.session[:id] }

        # The runner already announced the session ("New/Resuming session: <id>");
        # re-printing the full uuid here was the third copy of the same id on boot
        # (#82). The short id is enough; the full one lives in /status.

        # Best-effort: a closed terminal / kill marks the session ended too (#100).
        prev_signal_traps = install_session_end_traps(runner)

        swap_runner!(runner, ui)
        cmd_loader = Rubino::Commands::Loader.new

        # The bottom composer is now the SINGLE input path (idle AND in-turn): one
        # pinned-bottom editor with full editing parity, so output/reasoning/
        # footers commit ABOVE the prompt and out-of-band keys can't smear the
        # stream. Build its shared completion source + history once; #next_input
        # routes the idle prompt through a composer wired with them. A plain
        # cooked readline remains the fallback for non-TTY / piped / -q input.
        @completion_source = Chat::CompletionBuilder.new(cmd_loader).build
        @input_history     = Rubino::UI::InputHistory.new

        if session_resolver.resuming_session?
          # On a bare-chat auto-resume (#99) tell the user, clearly and once,
          # that we picked up their last session and how to start fresh —
          # otherwise the continuation is silent and looks like a fresh boot.
          session_resolver.print_auto_resume_line(ui, runner.session) if session_resolver.auto_resumed_session
          note_if_resuming_compacted_parent(runner, ui: ui)
          session_resolver.print_session_history(ui, runner.session[:id])
        else
          # First-run welcome panel: the same assembler /status uses, trimmed.
          Rubino::Commands::Executor.welcome(runner: runner, ui: ui)
        end

        # `chat --image/-i` without -q: stage the flag paths into the SAME
        # pending-attachment inbox @image tokens, /paste and dropped paths fill
        # (#160) — the flag used to be consumed only by the one-shot path, so
        # in interactive mode it was silently dropped.
        stage_flag_images(ui)

        # Steering: lines the user types *during* a turn are captured by the
        # background reader (see #run_turn) and parked here. At the next turn
        # boundary we drain them and they become the next prompt, so a message
        # typed while the agent was working is answered as the next turn with
        # no copy/paste — instead of blocking on a fresh readline.
        input_queue = Rubino::Interaction::InputQueue.new

        # Drive the turn-scoped status row from bus events the UI doesn't see
        # directly: MESSAGE_COMPLETED (a streamed block ended — commit its tail
        # and resume the row between blocks, the P4 inter-tool gap) and
        # JOB_STARTED/JOB_FINISHED (the post-turn inline jobs spending aux-LLM
        # seconds after the footer — the P6 "polishing" phase). Both arrive on
        # the process-global bus the interactive runner and the inline job
        # runner emit on. Best-effort: a UI hiccup must never fail the source.
        subscribe_status_row_events(ui)

        # Reset the shared explicit-queue stack for this interactive session (see
        # #pending_queued): live "⏳ queued: <msg>" rows the composers render and
        # the loop commits as normal messages when their turn runs.
        @pending_queued = []

        # Keep structured JSON log lines OUT of the raw-mode TUI (#125): for the
        # whole interactive session the logger writes to a file in the logs dir
        # instead of the terminal $stdout the renderer owns. A warn/info event
        # (e.g. a network blip while a background subagent runs) would otherwise
        # be dumped as raw JSON into the rendered conversation, corrupting the
        # bottom-composer frame. Restored on teardown. Logs are not lost — they
        # go to the file.
        prev_log_io = redirect_logger_to_file

        interacted = false
        begin
          loop do
            input = next_input(input_queue, runner)
            # Esc-Esc rewind: the idle read forked the session at the picked
            # message and parked the fork's runner — adopt it BEFORE dispatch
            # so the edited message runs as the next turn on the fork (the
            # same swap-in-place /branch and /compact do).
            if (rewound = @rewound_runner)
              @rewound_runner = nil
              runner = swap_runner!(rewound, ui)
            end
            if input.nil? || exit_command?(input)
              break if confirm_quit?(ui)

              next
            end
            next if input.strip.empty?

            input = input.strip

            # The single most likely first keystroke for a newcomer is a bare
            # `help` (or `commands`/`?`). Routing it to the LLM burns a slow,
            # multi-thousand-token turn to answer what `/help` shows instantly.
            # Treat these aliases as the slash command so they dispatch locally.
            input = help_alias_to_command(input)

            # Return to the main session — from the ← back-out, the picker's "◂
            # main" row, or a typed /detach: detach if attached, a harmless no-op
            # at the main prompt. Handled before the attached-input intercept so it
            # works in both states.
            if %w[/detach /back].include?(input)
              detach_agent_view(runner, ui) if attached_to_agent?
              next
            end

            # While ATTACHED to a subagent (the agent-view), the prompt is scoped
            # to it: the line NEVER runs a parent turn. A `/`-line is an
            # agent-scoped command; anything else steers the child (or answers it
            # when it is blocked on you). The `--attach` command that ENTERS this
            # mode (from the main prompt) arrives while @attached_id is still nil,
            # so it falls through to normal dispatch below.
            if attached_to_agent?
              handle_attached_input(input, runner, ui, @cmd_executor)
              next
            end

            # Image-input commands manipulate the pending-attachment state local
            # to this REPL (not the agent), so they're handled here before the
            # slash dispatcher. `/paste` grabs a clipboard image; `/clear-images`
            # drops anything queued.
            if image_inbox.handle_image_command(input, ui)
              commit_queued_dispatch
              next
            end

            # Pull any image references (@image, dropped/quoted path) out of the
            # line into image_paths (the native vision slot); the rest stays text.
            # An image-only line STAGES the attachment instead of submitting an
            # empty turn (#100): the in-prompt hint promises a "sent with your
            # next message (/clear-images to drop)" window, so honour it for
            # @image/dropped paths the same as /paste — the image goes out with
            # the next message that carries text.
            input = image_inbox.extract_images!(input, ui)
            if input.empty?
              commit_queued_dispatch
              next
            end

            # A leading `? ` is the one-keystroke ephemeral probe (Option A of
            # the locked UX): the rest of the line is a side-question answered
            # from the session context, rendered in a dim aside, then DISCARDED
            # — nothing is written to the transcript. Handled BEFORE slash
            # dispatch so `? /foo` is still a probe about a literal `/foo`.
            if (question = probe_question(input))
              commit_queued_dispatch
              run_probe(runner, question, ui)
              next
            end

            # A leading `!` is the human shell escape (Claude Code's bash
            # mode): run the rest of the line in the user's shell NOW — no
            # approval, the human typed it — stream the output into the
            # transcript, then inject command + output into the session as
            # user-role <bash-input>/<bash-stdout><bash-stderr> messages so
            # the model can reference them next turn. Handled BEFORE slash
            # dispatch so `!` always wins. :ran counts as interaction (the
            # session now has messages worth a resume hint); a bare-`!`
            # usage line (:handled) does not.
            case bang_shell.handle(input, runner, ui)
            when :ran
              interacted = true
              commit_queued_dispatch
              next
            when :handled
              commit_queued_dispatch
              next
            end

            if input.start_with?("/")
              # A dequeued line that resolves to a SLASH COMMAND never reaches
              # #run_turn, so #commit_queued_prompt would never fire for it and
              # its live "⏳ queued:" row would leak across later prompts
              # (#192). Commit it here — echo + drop the indicator — before the
              # command runs, whatever the dispatch result is.
              commit_queued_dispatch
              result = @cmd_executor.try_execute(input)
              case result
              when :exit
                # `/exit` / `/quit` dispatched through the slash executor must
                # honour the SAME quit-guard as Ctrl+D / a bare `exit` (#154):
                # confirm before killing in-flight background subagents instead
                # of breaking silently. The idle pre-filter above (#exit_command?)
                # already routes the bare/`/`-prefixed forms through
                # #confirm_quit?, but a slash form that reaches the executor (e.g.
                # an alias / a future quit verb that bypasses the pre-filter) must
                # not be a silent-kill back door — gate it here too so EVERY quit
                # path is consistent. Decline (live children + `n`) returns to the
                # prompt instead of exiting.
                break if confirm_quit?(ui)

                next
              when :handled then next
              when Hash
                if result[:probe]
                  # /probe <text>: same ephemeral side-inference as the `? `
                  # prefix, then discard. The teaching-only bare /probe returned
                  # :handled above, so this always carries a question.
                  run_probe(runner, result[:probe], ui)
                  next
                end
                if result[:branch]
                  # /branch [name]: fork the current session here into a new
                  # saved one (inheriting context + any preceding probe) and
                  # SWITCH into it, leaving the original intact.
                  runner = swap_runner!(branch_runner(ui, runner, result[:title]), ui)
                  next
                end
                if result[:attach_agent]
                  # Enter on the subagent picker: switch the whole timeline to
                  # that agent's (clear + replay) and scope the input to it. No
                  # turn runs; subsequent input is intercepted above until detach.
                  attach_agent_view(result[:attach_agent], ui)
                  next
                end
                if result[:resume_session_id]
                  # /sessions <id|title>: rebuild the runner on the chosen
                  # session in place and replay its history, then go back to the
                  # prompt — no process restart needed. Leaving a branch (e.g.
                  # back to the parent) drops the branch token from the status bar.
                  @branch_short_id = nil
                  runner = swap_runner!(resume_runner(ui, result[:resume_session_id]), ui)
                  next
                end
                if result[:compact_into]
                  # /compact: the compactor wrote head+summary+tail into a
                  # child session (the source is now status "compacted") —
                  # swap the runner into the child WITHOUT replaying history,
                  # so the next turn runs on the compacted context.
                  runner = swap_runner!(build_runner(session_id: result[:compact_into], ui: ui), ui)
                  next
                end
                if result[:new_session]
                  # /new: end the current session and rebuild the runner on a
                  # fresh one in place — the counterpart to the bare-chat resume.
                  # handoff: the REPL stays interactive, so the end-of-session
                  # memory flush is enqueued detached instead of blocking the
                  # prompt 2-3s on its aux-LLM extract (the new runner's worker
                  # drains it).
                  @branch_short_id = nil
                  runner.end_session!(handoff: true)
                  runner = swap_runner!(fresh_runner(ui), ui)
                  interacted = false
                  next
                end
                if result[:select_agent]
                  # `/agent <name>` (or a bare `/<primary>`): pin the primary
                  # agent for the rest of the session — its Definition rides the
                  # runner from the next turn, and the slot drives the status-bar
                  # chip + Tab cycle. No turn runs.
                  switch_primary_agent(result[:select_agent], runner, ui)
                  next
                end
                interacted = true
                # `/<agent> <message>` (or a custom command's `agent:` frontmatter)
                # routes THIS turn to the named agent's Definition without
                # disturbing the sticky pick; a nil/blank agent runs the sticky one.
                run_turn(runner, result[:prompt], ui, input_queue, agent_name: result[:agent])
              else interacted = true
                   run_turn(runner, input, ui, input_queue)
              end
            else
              interacted = true
              run_turn(runner, input, ui, input_queue)
            end
          end
        rescue Interrupt
          # A double-tap Ctrl+C inside run_turn re-raises to break out of the
          # REPL — exit cleanly instead of dumping a signal backtrace.
        ensure
          # Structured-concurrency teardown: the parent REPL is leaving (clean quit
          # OR the double-tap Ctrl+C break above), so cancel every live subagent
          # before we return. Without this a child blocked on ask_parent(blocking)
          # stays parked on its gate for the full ask_parent_timeout (~900s) — the
          # parent that owed it an answer is gone, but nothing wakes its gate.
          # #shutdown! wakes each within one WAKE_TICK so it unwinds via its
          # `rescue Rubino::Interrupted` with the clean "cancelled" message. If a
          # child is stuck in a provider read and never observes the cancel token,
          # it force-kills the Ruby thread so the REPL can actually exit. No-op
          # when there are no children.
          Tools::BackgroundTasks.instance.shutdown!
          restore_signal_traps(prev_signal_traps)
          restore_logger(prev_log_io)
        end

        # Mark the session ended on a clean teardown (#100) so it stops showing
        # as "active" forever and cleanup/--continue can tell finished from live.
        runner.end_session!

        ui.blank_line
        ui.info("Session ended.")
        session_resolver.print_resume_hint(ui, runner.session) if interacted

        # Field standard: a session that surfaced an AUTH/credential error must
        # NOT report success on exit (git/gh/Claude Code/Codex all exit non-zero
        # on a credential failure). The interactive REPL deliberately stays alive
        # after a failed turn (the user can fix their key and retry), so the
        # failure is latched on the runner and the NON-ZERO exit is deferred to
        # here — after the clean teardown. A session that never hit an auth error
        # keeps its normal exit 0, so clean-quit behaviour is unchanged.
        exit(1) if runner.respond_to?(:auth_error?) && runner.auth_error?
      end

      # Best-effort: on a terminal close (SIGHUP) or kill (SIGTERM) mark the
      # current session ended too, so a closed window doesn't leave it looking
      # active (#100). The handler must stay trap-safe — one synchronous DB
      # update then exit; no I/O, no locking. Returns the previous handlers so
      # they can be restored on the normal exit path. nil for signals this
      # platform doesn't define (e.g. SIGHUP on Windows).
      def install_session_end_traps(runner)
        %w[HUP TERM].each_with_object({}) do |sig, prev|
          next unless Signal.list.key?(sig)

          prev[sig] = Signal.trap(sig) do
            # External teardown (systemd SIGTERM / terminal-close SIGHUP), not a
            # user interrupt: flip the cancel token with reason :external so any
            # in-flight turn that unwinds via Rubino::Interrupted is labeled
            # truthfully ("interrupted by external signal"), not "by user"
            # (#361b). Trap-safe — cancel! only flips lock-free booleans.
            runner.cancel!(reason: :external)
            # The process is about to exit(0): reap every shell process group a
            # subagent spawned (each its own pgid) so it does NOT reparent to
            # init as a live orphan (MED-2 / #465). This MUST stay trap-safe:
            # Ruby forbids Mutex#synchronize from a signal-trap context, so we do
            # NOT route through BackgroundTasks#cancel_all here (its #running /
            # #stop_entry / and the old #kill_all_groups all take a mutex →
            # ThreadError, which killed the whole trap and left the shells
            # orphaned, #478). #kill_all_groups now reads a lock-free pgid
            # snapshot and only calls Process.kill/sleep — both async-signal-safe.
            # The cooperative subagent-gate cancel #cancel_all also does is moot
            # here: the threads die with this process at exit, and waking their
            # gates would need the forbidden lock.
            Tools::ShellRegistry.instance.kill_all_groups
            runner.end_session!
            exit(0)
          end
        rescue ArgumentError
          nil # signal not supported on this platform
        end
      end

      def restore_signal_traps(prev)
        return unless prev

        prev.each { |sig, handler| Signal.trap(sig, handler || "DEFAULT") }
      rescue ArgumentError
        nil
      end

      # Runs the one-shot turn under a cooperative SIGINT trap (#335a). The trap
      # is async-signal-safe: it only flips the runner's cancel token (a
      # single, lock-free, trap-safe boolean — see Interaction::CancelToken),
      # exactly like the interactive path. That cancels the in-flight LLM stream
      # at its next chunk checkpoint (the adapter raises Rubino::Interrupted out
      # of the per-chunk callback, which unwinds Faraday's net-http read loop and
      # closes the socket — no drain, no late-token bleed). The Interrupted then
      # propagates to the caller's rescue, which prints a clean notice and exits
      # 130. The trap is always restored. Platforms without SIGINT (Windows)
      # just run the block — Signal.trap raises ArgumentError, swallowed.
      def with_oneshot_int_trap(runner)
        installed = false
        begin
          prev = Signal.trap("INT") { runner.cancel! }
          installed = true
        rescue ArgumentError
          # SIGINT not supported on this platform — run without the trap.
        end
        # Also arm the EXTERNAL teardown traps (#389/residual #378): the HUP/TERM
        # handler was wired ONLY into the interactive REPL, so a SIGTERM during a
        # HEADLESS one-shot fell through to a bare SignalException that
        # oneshot_external_interrupt? treats as a user Ctrl-C — mislabeling a
        # systemd/operator kill as "interrupted by user". Install the same
        # external trap here so SIGTERM → cancel!(reason: :external) → the
        # in-flight turn unwinds via Rubino::Interrupted(reason: :external) into
        # the one-shot rescue and is labeled "interrupted by external signal" /
        # subtype error_external_signal. SIGINT keeps flowing through the trap
        # above (no reason) and stays a user interrupt.
        prev_ext = install_oneshot_external_traps(runner)
        yield
      ensure
        if installed
          begin
            Signal.trap("INT", prev || "DEFAULT")
          rescue ArgumentError
            nil
          end
        end
        restore_signal_traps(prev_ext)
      end

      # Arms the SIGHUP/SIGTERM external-teardown traps for the HEADLESS one-shot
      # path (#389). Unlike the interactive install_session_end_traps, the
      # handler does NOT exit(0): it flips the cancel token with reason :external
      # (so the in-flight turn unwinds via Rubino::Interrupted and the existing
      # one-shot rescue prints the persisted partial and the truthful external
      # label) and best-effort ends the session. Trap-safe — cancel! only flips
      # lock-free booleans; end_session! is a single synchronous DB update.
      # Returns the previous handlers for restore_signal_traps.
      def install_oneshot_external_traps(runner)
        %w[HUP TERM].each_with_object({}) do |sig, prev|
          next unless Signal.list.key?(sig)

          prev[sig] = Signal.trap(sig) do
            runner.cancel!(reason: :external)
          end
        rescue ArgumentError
          nil # signal not supported on this platform
        end
      end

      # Install the idle-prompt SIGINT trap (BH-2). The block is the whole
      # handler body and MUST be trap-safe — the caller passes one that only
      # flips a plain flag (no Mutex, no I/O), exactly like the during-turn INT
      # trap. Returns the previous handler so #restore_idle_int can put it back.
      # nil (no trap installed) on a platform without SIGINT.
      def trap_idle_int(&)
        Signal.trap("INT", &)
      rescue ArgumentError
        nil
      end

      # Restore whatever INT handler was in place before the idle read armed its
      # own (the session-end / default handler), so the trap never leaks past the
      # idle prompt into a turn (which installs its own double-tap INT trap).
      def restore_idle_int(prev)
        Signal.trap("INT", prev || "DEFAULT")
      rescue ArgumentError
        nil
      end

      # Routes the structured logger to a file for the interactive session so
      # JSON log lines never reach the terminal $stdout the TUI renders into
      # (#125). Returns the previous sink IO to restore on exit; nil (no-op,
      # logger untouched) if the file can't be opened — a logging-destination
      # detail must never break the chat boot.
      def redirect_logger_to_file
        dir = File.expand_path(Rubino.configuration.dig("paths", "logs") || "~/.rubino/logs")
        FileUtils.mkdir_p(dir)
        file = File.open(File.join(dir, "rubino.log"), "a") # rubocop:disable Style/FileOpen -- the sink must outlive this method
        file.sync = true
        Rubino.logger.reopen(file)
      rescue StandardError
        nil
      end

      # Restores the logger's sink to whatever it was before the interactive
      # session redirected it (typically $stdout). No-op when redirection was
      # skipped (prev nil).
      def restore_logger(prev)
        return unless prev

        Rubino.logger.reopen(prev)
      rescue StandardError
        nil
      end

      # Relays bus events into the turn-scoped status row. Subscribed once per
      # interactive session on the process-global bus:
      #   MESSAGE_COMPLETED — the adapter closed one streamed content block;
      #     the UI commits the block's tail and resumes the row so the gap
      #     until the next tool/block isn't dead air (P4). Subagents run on
      #     their own per-task bus, so their blocks never reach this listener.
      #   JOB_STARTED/JOB_FINISHED — the inline post-turn jobs (memory extract,
      #     skill distill); the row shows "polishing · memory|skills" (P6).
      # Every callback is fully rescued: a cosmetic repaint failure must never
      # bubble into the emitter (it would fail the job / abort the stream).
      def subscribe_status_row_events(ui)
        return if @status_row_subscribed

        @status_row_subscribed = true
        bus = Rubino.event_bus
        bus.on(Rubino::Interaction::Events::MESSAGE_COMPLETED) do |payload|
          ui.stream_block_end(payload[:message_id]) if ui.respond_to?(:stream_block_end)
        rescue StandardError
          nil
        end
        bus.on(Rubino::Interaction::Events::JOB_STARTED) do |payload|
          ui.job_started(payload[:type]) if ui.respond_to?(:job_started)
        rescue StandardError
          nil
        end
        bus.on(Rubino::Interaction::Events::JOB_FINISHED) do |payload|
          ui.job_finished(payload[:type]) if ui.respond_to?(:job_finished)
        rescue StandardError
          nil
        end
      end

      # Shared stack of EXPLICITLY-queued messages (Alt+Enter / "/queued"),
      # rendered as live "⏳ queued: <msg>" rows above whichever composer is
      # current (idle or in-turn) and removed — the item committed as a normal
      # "<prompt><msg>" message — when its turn actually runs (see #run_turn).
      # Memoized so it survives the per-turn composer teardown AND so unit tests
      # that drive #read_idle_line / #start_composer directly (without going
      # through #run_interactive) still get a real list, not nil.
      def pending_queued
        @pending_queued ||= []
      end

      # Next prompt for the REPL. If the user typed while the previous turn
      # ran, those lines were parked in the InputQueue; consume them as the
      # next prompt INSTEAD of blocking on a fresh readline. Each parked line is
      # taken ONE at a time (FIFO) and run as its OWN turn (B4) — an
      # interrupt-by-default Enter, an Alt+Enter, or a "/queued" each get their
      # own turn in submission order, never coalesced into a single
      # newline-joined message. The remaining queued items stay parked (their
      # "⏳ queued:" indicators remain) and each runs on a later #next_input.
      # When nothing is queued, fall back to the normal readline prompt.
      # +runner+ (optional) feeds the status bar under the idle composer —
      # model id + context saturation for the CURRENT session, refreshed at
      # this turn boundary (and so on session resume/branch/new too, which all
      # rebuild the runner before the next idle prompt).
      # Pops any text the user typed during a synchronous /probe wait (#221),
      # parked on the UI by ProbeWaitIndicator. nil on adapters that don't stash.
      def probe_draft_stash
        ui = Rubino.ui
        ui.take_probe_draft if ui.respond_to?(:take_probe_draft)
      end

      def next_input(input_queue, runner = nil)
        # Take the OLDEST parked line (FIFO). Mark it so #run_turn commits the
        # normal "<prompt><line>" echo (and clears any "⏳ queued:" indicator)
        # when this line runs. The rest stay queued for their own later turns.
        queued = input_queue.shift
        unless queued.nil?
          @input_from_queue = [queued]
          return queued
        end
        @input_from_queue = nil

        # Carry over any draft the user typed into the bottom composer during the
        # previous turn but never submitted (no Enter): the turn-scoped composer
        # is torn down at turn end, so without this the in-progress text would
        # vanish. Consume it once — the next idle prompt starts empty again.
        draft = @pending_draft
        @pending_draft = nil
        # A synchronous /probe wait owned a transient composer to echo input
        # (#221); anything typed there was parked on the UI and is restored into
        # this prompt's draft so it reappears in `❯` after the peek.
        if (probe_draft = probe_draft_stash) && !probe_draft.empty?
          draft = draft.to_s.empty? ? probe_draft : "#{draft}#{probe_draft}"
        end

        # The bottom composer is the single idle input path on a real TTY: it
        # pins the prompt at the bottom, owns its own raw reader (so keys can't
        # smear the stream), updates the status bar's mode token LIVE on
        # Shift+Tab, and hosts
        # the background-subagent card region (F1) when children are live. The
        # plain cooked readline is the fallback for non-TTY / piped / -q input.
        if UI::BottomComposer.active?
          read_idle_line(input_queue, draft, runner)
        else
          cooked_input(build_prompt, draft)
        end
      end

      # Reads the user's next line at the IDLE prompt through the bottom composer
      # — the single input path. The composer pins the prompt at the bottom and
      # owns its own raw reader (full editing parity: arrows/Home/End/word-jump,
      # ↑↓ history, /command + @file completion menu with immediate-Esc dismiss,
      # cyan token highlight), updates the status bar's mode token LIVE on
      # Shift+Tab, reveals
      # reasoning on Ctrl+O, and hosts the collapsed subagent card region (F1)
      # when background children are live — repaints land above the prompt and
      # update in place, serialized through the composer's render mutex.
      #
      # We seed the carried-over draft, then BLOCK until the user submits a line,
      # polling the same InputQueue the composer's reader pushes into (reusing the
      # turn loop's hand-off). A half-typed, un-submitted draft is preserved in
      # @pending_draft on teardown so it survives into the next prompt.
      def read_idle_line(input_queue, draft, runner = nil)
        # Esc-Esc rewind flag, flipped from the composer's reader thread and
        # drained by the poll loop below — the same trap-safe split the idle
        # Ctrl+C uses (the hook must never take the render mutex over there).
        # Declared BEFORE the composer so the lambda captures this local.
        # Without a runner there is no session to rewind, so no hook.
        rewind_pending = false
        # Idle Ctrl+C (#551): the composer reads \x03 as a BYTE and calls this
        # hook (raw(intr: true) does NOT reliably keep ISIG on — on Darwin Ctrl+C
        # is swallowed without raising SIGINT, so the in-band byte is the only
        # dependable signal). It just flips the flag the poll loop below drains
        # to run the clear/two-tap-exit through #idle_interrupt — declared here so
        # the lambda captures it.
        int_pending = false
        composer = UI::BottomComposer.new(
          input_queue: input_queue,
          prompt: build_prompt,
          rail: composer_rail,
          on_ctrl_o: ctrl_o_handler,
          on_mode_cycle: mode_cycle_handler(runner),
          on_agent_cycle: agent_cycle_handler(runner),
          completion_source: @completion_source,
          history: @input_history,
          echo: :prompt,
          pending_queued: pending_queued,
          status_line: build_status_line(runner),
          max_input_rows: Rubino.configuration.display_input_max_rows,
          paste_store: paste_store,
          on_double_esc: runner ? -> { rewind_pending = true } : nil,
          on_idle_interrupt: -> { int_pending = true },
          # ONE Esc cancels the detached post-turn polishing (#319): only when
          # it's actually in flight, so a stray idle Esc still falls through to
          # the rewind chord. Trap-safe — flips the polishing cancel token only.
          on_escape: idle_polishing_escape(runner),
          # While attached to a subagent, ← on the empty scoped prompt detaches to
          # the main timeline (arrows + Enter only — the picker's "◂ main" row does
          # the same). Routed through the input queue so the idle loop runs it the
          # same way a typed /detach would. nil when not attached.
          on_back: (attached_to_agent? ? -> { input_queue.push("/detach") } : nil)
        )
        composer.start
        # Route $stdout through the composer for the whole idle read — the SAME
        # StdoutProxy swap a turn gets — so anything printed while the idle
        # prompt is pinned (a background subagent's completion note, a late
        # status line) commits ABOVE the input under the composer's render
        # mutex instead of raw-painting over the prompt row (#169). The logger
        # is forced to bind to the real IO first, exactly as in #start_composer.
        real_stdout = $stdout
        Rubino.logger
        $stdout = UI::StdoutProxy.new(composer)
        seed_draft(composer, draft)
        idle_cards.paint
        ticker = idle_cards.children_live? ? idle_cards.start_ticker(composer) : nil

        # SIGINT trap as a FALLBACK only (BH-2 / #551): the dependable idle Ctrl+C
        # path is now the in-band \x03 byte (on_idle_interrupt above), because
        # raw(intr: true) does NOT reliably raise SIGINT (Darwin swallows it). On
        # the platforms where the signal DOES still arrive we keep this trap so a
        # stray SIGINT flips the SAME int_pending flag (the poll loop drains it
        # via #idle_interrupt) instead of hitting the default handler and quitting,
        # silently discarding a typed draft. Trap-safe (flip a flag only — Mutex
        # is forbidden in a trap, Ruby #14222); restored in the ensure so it never
        # leaks past the idle read.
        prev_int = trap_idle_int { int_pending = true }

        # Non-blocking "polishing… (Esc to skip)" indicator (#319): the detached
        # post-turn polishing is still running while THIS idle prompt is live, so
        # surface a dim status line that does NOT own the input — the composer is
        # active with the cursor in the box, the user can type immediately. We
        # only swap the status line on a state CHANGE (running ↔ idle) so the bar
        # never busy-repaints, restoring the model/context line on completion.
        polishing_shown = false
        line = nil
        loop do
          polishing_shown = update_polishing_indicator(composer, runner, polishing_shown)
          # Drained the idle Ctrl+C the trap recorded: clear the draft (non-empty)
          # or arm/confirm the two-tap exit (empty). Done here, not in the trap,
          # so the render mutex is safe.
          if int_pending
            int_pending = false
            break if composer.idle_interrupt(window: DOUBLE_TAP_SECONDS) == :exit
          end

          # Single Ctrl+D at the empty idle prompt (or a closed stdin): the
          # reader saw an EOF/quit and STOPPED — surface it here as nil (EOF) so
          # #read_idle_line returns and the REPL quit-guard (#confirm_quit?)
          # runs. Without this the loop would sleep-spin forever (the reader is
          # gone and never pushes a line). Mirrors the Ctrl+C path above. A
          # Ctrl+D on a NON-empty buffer is delete-forward, not quit, so it never
          # sets the flag — that affordance is preserved.
          if composer.quit_pending?
            composer.clear_quit_pending
            line = nil
            break
          end

          # Auto-open the EXISTING approval / reply prompt for a pending subagent
          # request (#421): a parked child needs a human decision, so the
          # affordance presents ITSELF here at idle instead of leaving a passive
          # card the user must answer by guessing `/agents <id>` / `/reply <id>`.
          # This is the SAME prompt those slash commands open — just auto-opened.
          # Because the REPL re-enters this idle loop at EVERY turn boundary
          # (including after an interrupted/aborted turn), a request that arrived
          # mid-turn or survived an abort is re-detected here and never lost. The
          # prompt runs under run_in_terminal (the @ui.ask/@ui.select primitives
          # suspend THIS composer and restore it after), so it does not race the
          # reader. Resolves one request, then `next` so the cards repaint and the
          # loop re-checks for the next pending request before reading input.
          if auto_resolve_pending_subagent_request(runner)
            idle_cards.paint
            next
          end

          # Non-blocking idle completion affordance (item 5): announce any
          # background subagent that finished while we've been idle, then carry on
          # reading input — the parent never blocks or polls for a child.
          surface_finished_subagents

          # Take ONE parked line (FIFO) so several items queued at idle each run
          # as their OWN turn (B4), in submission order — never coalesced. The
          # rest stay parked for the next #next_input / loop pass. Checked
          # BEFORE the rewind flag: a line the user already submitted wins over
          # an Esc-Esc that raced it (the pending rewind dies with the break —
          # a picker must never pop over a turn that is about to start).
          queued = input_queue.shift
          unless queued.nil?
            # An idle plain submit already echoed "<prompt><line>" at submit time;
            # only an EXPLICITLY-queued item (Alt+Enter / "/queued" at idle, which
            # carries a "⏳ queued:" indicator and no echo yet) needs run_turn to
            # commit it as a normal message. Flag just that so a plain submit is
            # never double-echoed.
            @input_from_queue = pending_queued.include?(queued) ? [queued] : nil
            line = queued
            break
          end

          # AUTONOMOUS background-subagent resume (#561): no typed line is
          # waiting, but one or more children finished AFTER the parent's turn
          # ended and parked their `[background-task]` completion notices. The
          # mid-turn fold-in (Loop#inject_steered_input) only fires while the
          # parent is still iterating, so two children + "wait for both" left the
          # parent idle forever — the combined result never delivered. Here we
          # COALESCE every parked notice into ONE follow-up turn and return it as
          # the next prompt, so the parent resumes on its own and summarises the
          # results. Guards:
          # - notices_pending? is false the moment a typed line exists (it wins
          #   via #shift above and folds the notices in on its own turn), so an
          #   in-progress prompt is never pre-empted;
          # - the buffer guard defers while the user is mid-line (the notice stays
          #   parked, never discarded, and rides the line the user submits);
          # - the drain is atomic and one-shot, so the same completions can't
          #   re-trigger a second turn.
          if input_queue.notices_pending? && idle_buffer_empty?(composer)
            notices = input_queue.drain_notices
            unless notices.empty?
              line = coalesced_resume_prompt(notices)
              # Synthetic resume, not a user submission: do NOT echo it as a typed
              # message (no @input_from_queue), the notices are already surfaced
              # above the prompt by #surface_finished_subagents.
              @input_from_queue = nil
              break
            end
          end

          # Drain an Esc-Esc the reader recorded: open the rewind picker (it
          # suspends the composer via run_in_terminal, so it must run on THIS
          # thread, never the reader's). A pick forks the session, parks the
          # fork in @rewound_runner for the REPL to adopt, and pre-fills the
          # composer with the picked message; Esc-cancel changes nothing.
          if rewind_pending
            rewind_pending = false
            if (rewound = handle_rewind(composer, runner, Rubino.ui))
              runner = rewound
              @rewound_runner = rewound
            end
          end
          sleep(0.05)
        end
        line
      ensure
        restore_idle_int(prev_int)
        ticker&.kill
        ticker&.join
        # Mirror #stop_composer: restore the real $stdout, then flush any held
        # partial line through the still-live composer before tearing it down.
        if real_stdout
          proxy = $stdout
          $stdout = real_stdout
          proxy.finish if proxy.respond_to?(:finish)
        end
        if composer
          pending = composer.buffer.to_s
          @pending_draft = pending unless pending.strip.empty?
        end
        composer&.stop
      end

      # The idle composer's single-Esc hook (#319): cancel the detached post-turn
      # polishing IF it's in flight (returns true → the composer consumes the
      # Esc), else nil so the Esc falls through to the rewind chord. Runs on the
      # composer's reader thread, so it only flips the polishing cancel token —
      # the cooperative aux retry loop and the worker pick it up. nil runner
      # (no session) ⇒ no hook.
      def idle_polishing_escape(runner)
        return nil unless runner

        lambda {
          next nil unless runner.polishing?

          runner.cancel!
          true
        }
      end

      # Keep the non-blocking polishing indicator in sync with the detached
      # worker's liveness, repainting only on a state change. Returns the new
      # "shown?" flag. While running: a dim "polishing memory… (Esc to skip)"
      # line under the still-active input. On completion: restore the normal
      # model/context status bar. A cosmetic repaint must never break the prompt.
      def update_polishing_indicator(composer, runner, shown)
        return shown unless composer.respond_to?(:set_status)

        running = runner&.polishing? || false
        return shown if running == shown

        composer.set_status(running ? polishing_status_line : build_status_line(runner))
        running
      rescue StandardError
        shown
      end

      # The dim, non-blocking indicator text. Reads as background (not a block)
      # precisely because the composer stays editable beneath it (#319).
      def polishing_status_line
        pastel.dim("polishing memory… (Esc to skip)")
      rescue StandardError
        "polishing memory… (Esc to skip)"
      end

      # Seed a carried-over draft into the composer char-by-char so cursor/delete
      # stay codepoint-granular (handle_key edits one codepoint at a time).
      def seed_draft(composer, draft)
        return if draft.nil? || draft.to_s.empty?

        draft.to_s.each_char { |c| composer.handle_key(c) }
      end

      # Plain cooked prompt for non-TTY / piped / scripted interactive input,
      # where the raw-mode composer can't run. Prints the prompt, reads one line,
      # and pre-pends any carried-over draft so it isn't lost. nil on EOF.
      def cooked_input(prompt, draft)
        $stdout.print(prompt)
        $stdout.flush
        line = $stdin.gets
        return nil if line.nil?

        line = line.chomp
        draft && !draft.to_s.empty? ? "#{draft}#{line}" : line
      rescue IOError
        nil
      end

      # Seeds the interactive pending-images inbox from --image/-i flag paths
      # (#160); the attachment gate + indicator live in Chat::ImageInbox.
      def stage_flag_images(ui)
        image_inbox.stage_flag_images(opt(:image), ui)
      end

      # Wraps a single turn: Ctrl+C cancels the in-flight generation and
      # drops back to the prompt, instead of killing the session.
      #
      # Aider-style double-tap (also how Codex/Claude Code behave): the first
      # INT during a turn cooperatively cancels and prints a hint; a second
      # INT within DOUBLE_TAP_SECONDS exits. The trap body must be trap-safe —
      # it only flips the mutex-free CancelToken (see CancelToken: Mutex#lock
      # is forbidden in a trap context, Ruby bug #14222) and reads/writes plain
      # locals; no locking, no I/O, no re-entrant trap. The previous handler is
      # always restored in +ensure+.
      #
      # Steering: when +input_queue+ is given and both ends are a TTY, a
      # bottom-pinned composer (UI::BottomComposer) runs alongside the turn so
      # the user can TYPE — with visible echo and backspace — while agent output
      # streams ABOVE the input line into native scrollback. Completed lines are
      # parked in the queue and picked up by the agent loop at the next ITERATION
      # boundary (Phase 2 — between tool steps, never mid-tool); anything still
      # queued after the turn ends falls back to #next_input as the next turn
      # (the MVP boundary).
      #
      # Output coordination: while the composer is live, $stdout is swapped for a
      # UI::StdoutProxy so the existing $stdout.print/puts call sites across
      # UI::CLI / PrinterBase route their output through the composer's
      # print_above instead of clobbering the input line — zero changes to those
      # call sites. The proxy is torn down and the terminal restored to cooked
      # mode in +ensure+ so raw mode / the swap never leak on a raise.
      def run_turn(runner, prompt, ui, input_queue = nil, agent_name: nil)
        # A real turn has happened, so any prior probe is no longer the
        # "immediately-preceding interaction" — a later /branch must NOT fold it
        # into the seed. Clear it here, the single chokepoint for real turns.
        @last_probe = nil

        # Pin the runner to the user's sticky primary agent (Tab / `/agent
        # <name>` set Rubino::ActiveAgent) so its Definition — system prompt +
        # tool scope — rides EVERY plain turn. A one-shot `/<agent> <message>`
        # passes +agent_name+ to run THIS turn under a different agent without
        # disturbing the pin (see #run below).
        runner.agent_definition = Rubino::ActiveAgent.definition if runner.respond_to?(:agent_definition=)

        # Consume the turn's queued image attachments (the native vision slot)
        # so they're attached exactly once, not re-sent next turn.
        image_paths = image_inbox.take!

        # The message-build seam of the paste pipeline: COLLECT each
        # "[Pasted text #N +M lines]" placeholder's full body (or the paste_N.txt
        # read-tool pointer for oversized ones) WITHOUT mutating the prompt. The
        # placeholder stays in the prompt — the message PERSISTED to the session
        # keeps it, so live echo AND resume replay show the compact token (#213)
        # — while the expansion map rides alongside as metadata, expanded into
        # the MODEL-FACING content by Message#to_context. Queued (Alt+Enter) and
        # history-recalled drafts collect here too, whichever turn they run as.
        paste_expansions = paste_store.expansions_in(prompt)

        # The interim idle-key GATE is retired: the bottom composer is now the
        # single input path and serializes every above-line write through its
        # render mutex, so Shift+Tab (mode footer) and Ctrl+O (reveal reasoning)
        # commit cleanly ABOVE the pinned prompt even DURING a turn — no
        # out-of-band $stdout race to smear the stream (the old D1/D3/D4 cause).
        last_int_at = nil
        in_trap     = false

        prev = Signal.trap("INT") do
          # Guard against trap re-entrancy: a burst of signals must not stack.
          unless in_trap
            in_trap = true
            begin
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              raise Interrupt if last_int_at && (now - last_int_at) <= DOUBLE_TAP_SECONDS

              # Second tap in the window: raise to the main thread so the
              # REPL unwinds and exits — a real Ctrl+C now quits.

              last_int_at = now
              runner.cancel!
              # The runner commits the standardized dim "⎿ interrupted" marker
              # once it unwinds the cancelled turn; here we only add the
              # actionable double-tap hint so the two don't restate the same
              # "interrupted" wording (L10).
              #
              # Route the hint through the composer's TRAP-SAFE transient
              # announce (#426): a raw "\n…\n" $stderr write here scrolled the
              # live region by two rows OUTSIDE LiveRegion's @rows_above
              # accounting, so on a very-early interrupt (the answer's first line
              # still a raw live-tail preview) the finalize commit's \e[1A
              # walk-up fell one row short — the raw preview survived above the
              # rendered line and the prompt committed as a ghost `❯` (Bug B,
              # the #265/#421 desync family). #announce_pending only assigns an
              # ivar (no mutex, no output — trap-safe); the interrupt's finalize
              # redraw paints it in place, leaving the geometry intact. With NO
              # composer owning the screen (plain TTY / pipe / headless) there is
              # no live region to desync, so fall back to the raw single $stderr
              # write — async-signal-safe enough for a trap — so the hint still
              # reaches the user on those paths exactly as before.
              hint = "(press Ctrl+C again to exit)"
              if (composer = UI::BottomComposer.current)
                composer.announce_pending(hint)
              else
                $stderr.write("\n#{hint}\n")
              end
            ensure
              in_trap = false
            end
          end
        end

        # Stale-flag guard (#111): a quiet suppression armed by a prior turn
        # that completed before observing its cancel must not swallow THIS
        # turn's real `⎿ interrupted` marker.
        ui.suppress_interrupt_marker(value: false) if ui.respond_to?(:suppress_interrupt_marker)

        composer, real_stdout = start_composer(input_queue, runner)

        # Mark the composer "in a turn" for the WHOLE turn — covering the THINKING
        # phase AND the content stream — so a "queued ▸" type-ahead echo submitted
        # before the first content token is deferred too, not stranded above the
        # thought line and the answer (D7e). Cleared (and the deferred echoes
        # flushed, after the footer) in the ensure below.
        composer.begin_turn if composer.respond_to?(:begin_turn)

        # Keep the collapsed subagent panel painted for the WHOLE turn, not just
        # at idle. When the user submits a new prompt WHILE background subagents
        # are still live, run_turn starts a FRESH composer (empty @cards) and the
        # idle ticker that had been repainting the panel died when the idle read
        # returned — so without this the panel vanishes through the thinking
        # phase and only reappears when the first child tap (a tool start/finish
        # repaint) fires. Paint the registry snapshot onto the new composer now
        # and run the SAME low-frequency ticker the idle prompt uses, so the
        # cards stay visible and their elapsed time advances until the turn ends.
        # Killed in the ensure below.
        idle_cards.paint
        card_ticker = idle_cards.children_live? ? idle_cards.start_ticker(composer) : nil

        # If this turn's prompt came off the input queue (interrupt-by-default
        # Enter, Alt+Enter, or "/queued" during the previous turn), commit it now
        # as a NORMAL "<prompt><line>" message above the input — the same echo an
        # idle submit gets — and remove its "⏳ queued:" indicator so it visibly
        # MOVES from the above-input pending row to a transcript message at send
        # time. An idle-submitted prompt already echoed at submit, so it isn't
        # marked and is skipped here (no double echo).
        commit_queued_prompt(composer)

        # Open the TURN-SCOPED status row (the "Ruby facet" ticker): one engine
        # thread for the whole turn — model waits, tools, inter-tool gaps AND
        # the post-turn inline jobs all just swap its label. Closed in the
        # ensure below (turn end / error / interrupt), so the post-footer
        # polishing phase stays animated instead of freezing the UI.
        ui.turn_started if ui.respond_to?(:turn_started)

        # Pass the SAME queue the composer pushes into through to the agent loop:
        # the loop drains it at each iteration boundary (Phase-2 mid-turn
        # steering). Anything still queued in the gap after the turn ends falls
        # back to #next_input for the NEXT turn (the MVP behaviour). nil ⇒ no
        # injection (piped/-q input has no composer anyway).
        run_kwargs = { image_paths: image_paths, input_queue: input_queue }
        # Only thread the paste expansions when a placeholder was actually
        # collected, so a normal turn's runner.run signature is unchanged.
        run_kwargs[:paste_expansions] = paste_expansions unless paste_expansions.empty?
        oneshot = one_shot_agent_definition(agent_name)
        if oneshot && runner.respond_to?(:run_with_agent)
          runner.run_with_agent(oneshot, prompt, **run_kwargs)
        else
          runner.run(prompt, **run_kwargs)
        end
      rescue Interrupt
        # Reached on the second tap (raised from the trap) or a stray INT that
        # escaped the cooperative path. Cancel and re-raise so run_interactive's
        # loop breaks and the session ends cleanly.
        runner.cancel!
        # This Ctrl-C-aborted turn may have orphaned a subagent blocked on
        # ask_parent(blocking:true): the parent turn that owed it an answer is
        # gone, so without this the child stays parked on its gate for the full
        # ask_parent_timeout (~900s). Cancel every live child so each unwinds NOW
        # via its `rescue Rubino::Interrupted` (clean "cancelled" message). The
        # re-raise also reaches run_interactive's teardown #cancel_all, but doing
        # it here keeps the unwind local to the edge that orphaned the child and
        # is idempotent, so the second call is a no-op.
        Tools::BackgroundTasks.instance.cancel_all
        ui.blank_line
        ui.warning("turn cancelled")
        raise
      ensure
        # End the turn BEFORE tearing the composer down: the runner has fully
        # unwound here, so the turn-summary footer is already in scrollback. This
        # clears the turn-active flag and flushes any deferred "queued ▸" echoes
        # via the still-live composer's print_above, so they land AFTER the footer
        # (answer → reveal → `↳ turn` → `queued ▸`). A no-content/aborted turn
        # still flushes here, so a mid-turn type-ahead is never stranded.
        # The status row stops FIRST — the post-turn jobs have drained by the
        # time the runner returns, so the facet has already landed in the
        # footer and the engine thread must not outlive the turn.
        ui.turn_finished if ui.respond_to?(:turn_finished)
        # Stop the during-turn panel ticker before tearing the composer down, so
        # it can't repaint over the next idle prompt (the idle read starts its
        # own ticker). Idempotent if it already exited on its own (no live child).
        card_ticker&.kill
        composer.end_turn if composer.respond_to?(:end_turn)
        # Refresh the status bar (model + context saturation) now that the
        # turn's messages are persisted — the "after each footer" boundary.
        # The bar then stays correct for however long this composer remains
        # pinned (post-turn inline jobs); the next idle composer recomputes it
        # at build time anyway.
        composer.set_status(build_status_line(runner)) if composer.respond_to?(:set_status)
        stop_composer(composer, real_stdout)
        Signal.trap("INT", prev) if prev
      end

      # The status-bar line for the CURRENT session (see UI::StatusBar):
      # mode (+ branch/skill when set) · resolved model id · context
      # saturation. Saturation derives from the SAME estimate the compaction
      # logic runs on — Context::TokenBudget#estimate_tokens (chars/4) over the
      # live message set — so the footer percentage and `needs_compaction?`
      # read one source and agree (no provider-usage override, which would make
      # the gauge disagree with what compaction decides). The window comes from
      # `model.context_length` / `context.max_tokens` (TokenBudget's default
      # otherwise), so the percentage tracks the compaction thresholds. nil (no bar) when
      # disabled via display.statusbar or on any failure: a cosmetic line
      # must never break the prompt.
      def build_status_line(runner)
        return nil unless runner && Rubino.configuration.display_statusbar?

        session  = runner.session
        budget   = Context::TokenBudget.new(model_id: session[:model], config: Rubino.configuration)
        messages = ::Rubino::Session::Store.new.for_session(session[:id])
        UI::StatusBar.render(
          chips: { mode: Rubino::Modes.current, agent: status_agent_chip,
                   branch: @branch_short_id,
                   skill: Rubino::ActiveSkill.current },
          model: session[:model] || model_name,
          tokens: context_tokens(messages, budget),
          window: budget.available_tokens,
          pastel: pastel
        )
      rescue StandardError
        nil
      end

      # The status-bar agent chip (#320): the active primary agent name, but
      # only when it differs from the registry default (build) — like the
      # branch/skill chips, a plain session keeps the bare bar. nil ⇒ no chip.
      def status_agent_chip
        current = Rubino::ActiveAgent.current
        default = Rubino.agent_registry.default&.name
        current if current && current != default
      end

      # Estimated tokens in the session's context — the SAME measure the
      # compaction trigger uses (Context::TokenBudget#estimate_tokens, chars/4
      # over the live message set), so the footer percentage and
      # `needs_compaction?` read from one source and AGREE. Previously the
      # footer preferred the provider's last per-turn `input_tokens` while
      # compaction estimated chars/4 over stored messages — two different
      # measures, so the gauge didn't reflect what compaction would decide.
      # The budget is the single token-count authority; we don't re-add the
      # provider usage on top (that would double-count against this estimate).
      def context_tokens(messages, budget)
        budget.estimate_tokens(messages.map { |m| { content: m.content } })
      end

      # Commits the just-dequeued prompt as a normal "<prompt><line>" transcript
      # message and removes its "⏳ queued:" indicator. Each line the previous
      # turn parked (set in #next_input as @input_from_queue) is echoed in the
      # clean "❯ " prompt, so a queued/interrupt-sent message reads back exactly
      # like an idle submit. No-op when the prompt was an idle submit (already
      # echoed) or there's no composer (piped / -q). Clears the marker after.
      def commit_queued_prompt(composer)
        lines = @input_from_queue
        @input_from_queue = nil
        return unless lines && composer

        lines.each do |line|
          # Drop the live "⏳ queued:" row first (explicit-queue items), then
          # commit the normal echo above the input.
          composer.commit_queued(line) if composer.respond_to?(:commit_queued)
          # USER-SUPPLIED line: neutralize terminal escapes before the echo
          # (CWE-150 — H1), the same render-boundary defense the approval card
          # and the composer's idle echo use. The raw line already went to the
          # model via the input queue; only this scrollback echo is sanitized.
          composer.print_above("#{build_prompt}#{Rubino::Util::Output.sanitize_terminal(line.to_s)}")
        end
      end

      # The NON-TURN counterpart of #commit_queued_prompt (#192): a dequeued
      # line consumed by the dispatch loop WITHOUT running a model turn (a slash
      # command, a `!` shell escape, a `? ` probe, an image command) never
      # reaches #run_turn, so its "⏳ queued:" indicator would linger above the
      # composer across later prompts. Commit it here instead: drop the row from
      # the shared pending stack (the next composer renders from it) and echo
      # the line as the normal "<prompt><line>" message — no composer is live
      # between turns, so the echo goes straight to scrollback. No-op for an
      # idle submit (not flagged in @input_from_queue).
      def commit_queued_dispatch
        lines = @input_from_queue
        @input_from_queue = nil
        return unless lines

        lines.each do |line|
          idx = pending_queued.index(line)
          pending_queued.delete_at(idx) if idx
          # USER-SUPPLIED line: neutralize terminal escapes before the echo
          # (CWE-150 — H1), like #commit_queued_prompt — the literal text already
          # reached the model; only this scrollback echo is sanitized.
          $stdout.puts("#{build_prompt}#{Rubino::Util::Output.sanitize_terminal(line.to_s)}")
        end
      end

      # Starts the bottom-pinned composer for the duration of a turn and swaps
      # $stdout for a proxy that routes all turn output through it.
      #
      # Returns [composer, real_stdout]. Both are nil unless steering is wired
      # AND both ends are real TTYs (UI::BottomComposer.active?) — for piped /
      # `-q` / server input there is nothing to read raw and we must not touch
      # terminal modes or swap $stdout, so this is a no-op there and the plain
      # path runs exactly as before.
      #
      # Terminal mode: the composer reader runs inside +$stdin.raw(intr: true)+
      # so each keystroke arrives unbuffered while +intr: true+ keeps the ISIG
      # flag on — Ctrl+C still generates SIGINT and reaches the double-tap trap
      # installed above (we never read or swallow \x03). The block form of #raw
      # restores the prior termios; #stop additionally forces cooked mode.
      #
      # The composer only appends to the thread-safe InputQueue; it never mutates
      # the runner or the agent loop, so it cannot race the turn own work — the
      # parked text is consumed by the loop at a safe iteration boundary (atomic
      # #drain), or by #next_input between turns for anything typed in the gap.
      def start_composer(input_queue, runner)
        return [nil, nil] unless input_queue && UI::BottomComposer.active?

        # The mode/branch/skill context rides the STATUS BAR (build_status_line);
        # the prompt itself is the constant clean "❯ " behind the red rail.
        # `runner` is threaded in (not captured from an enclosing scope) so the
        # interrupt lambda resolves it — it is a parameter of #run_turn, not in
        # scope here, and there is no @runner ivar, so capturing it implicitly
        # raised NameError the instant an Enter-during-turn fired (BH-1).
        # Same completion + history wiring as the idle composer: the prompt is
        # pinned and editable for the WHOLE turn — including the post-turn
        # window where inline jobs (memory auto-extract, skill distill) spend
        # aux-LLM seconds after the `↳ turn` footer — so `/` and `@` dropdowns
        # and ↑↓ history work whenever the prompt is visible (#169).
        busy = busy_command_handler(runner)
        composer = UI::BottomComposer.new(input_queue: input_queue, prompt: build_prompt,
                                          rail: composer_rail,
                                          on_ctrl_o: ctrl_o_handler,
                                          on_mode_cycle: mode_cycle_handler(runner),
                                          on_interrupt: interrupt_handler(runner),
                                          completion_source: @completion_source,
                                          history: @input_history,
                                          pending_queued: pending_queued,
                                          status_line: build_status_line(runner),
                                          max_input_rows: Rubino.configuration.display_input_max_rows,
                                          paste_store: paste_store,
                                          # ← on an empty prompt backs out of an attached subagent view to the
                                          # main timeline MID-TURN too (slice 3): routed through the SAME busy
                                          # handler typed lines use so the detach happens IMMEDIATELY on the
                                          # reader thread (not queued behind the still-running turn). Guarded by
                                          # attached_to_agent? so it's a no-op cursor key when not attached.
                                          on_back: -> { busy.call("/back") if attached_to_agent? },
                                          on_busy_command: busy)
        composer.start
        real_stdout = $stdout
        # Force the lazily-built logger to bind to the REAL $stdout NOW, before
        # the swap — otherwise the first log call during the turn would build a
        # Logger against the proxy and route diagnostic lines into the chat (and,
        # after the turn, into a dead proxy). The logger stays on the real IO.
        Rubino.logger
        $stdout = UI::StdoutProxy.new(composer)
        [composer, real_stdout]
      rescue StandardError
        # Setup failed — fall back to the plain path so the turn still runs
        # (no raw, no proxy).
        composer&.stop
        $stdout = real_stdout if real_stdout
        [nil, nil]
      end

      # The composer's ESC-during-turn hook (#421 — Esc is the interrupt now,
      # Enter queues): cancel the runner so the current turn unwinds (committing
      # `⎿ interrupted`) and the chat loop runs the HEAD of the queue next
      # (#next_input FIFO). Reuses the SAME runner.cancel! cancel-token machinery
      # Ctrl+C uses. +quiet+ (retained for a future quiet caller, #111) tells the
      # UI to swallow the `⎿ interrupted` marker; Esc passes false (a deliberate,
      # visible interrupt), so the marker is shown.
      def interrupt_handler(runner)
        lambda { |quiet = false|
          ui = Rubino.ui
          ui.suppress_interrupt_marker if quiet && ui.respond_to?(:suppress_interrupt_marker)
          runner.cancel!
        }
      end

      # The composer's BUSY-TIME input gate (#421): a line typed WHILE A TURN IS
      # ACTIVE is normally queued, but a local READ-ONLY/CONTROL meta-command
      # (/agents, /stop, /status, /jobs, /help, /commands, /tasks, /dirs) must
      # run IMMEDIATELY — watching a live subagent or cancelling one is useless
      # once parked behind a long turn. Returns the disposition the composer acts
      # on (:immediate / :blocked / :pass — see Executor#busy_disposition); for
      # :immediate it ALSO dispatches the command NOW, on the reader thread,
      # through the SAME Executor#try_execute path the post-turn dispatch uses.
      # The immediate set is read-only/control by construction, and its output
      # routes through the composer's render-mutex-serialized UI (StdoutProxy),
      # so it cannot corrupt the streaming turn; /stop reuses the same cancel
      # machinery Esc / `--stop` use, already safe to call concurrently. A
      # state-mutating command returns :blocked and is NOT run here — the
      # composer shows a transient notice. Any setup failure degrades to :pass
      # so the line simply queues (the legacy behavior), never crashing the read.
      def busy_command_handler(runner)
        executor = Rubino::Commands::Executor.new(ui: Rubino.ui, runner: runner)
        lambda do |line|
          # While ATTACHED to a sub mid-turn (Slice 3): every typed line is
          # SCOPED to the sub, not the running parent — detach on /back|/detach,
          # otherwise steer/answer the child (the same routing the idle loop's
          # #handle_attached_input does). Return :immediate so the composer does
          # NOT queue it as a parent steer. The parent turn keeps running.
          if attached_to_agent?
            ui = Rubino.ui
            if %w[/detach /back].include?(line.strip)
              detach_agent_view(runner, ui)
            else
              handle_attached_input(line, runner, ui, executor)
            end
            next :immediate
          end

          disposition = executor.busy_disposition(line)
          if disposition == :immediate
            result = executor.try_execute(line)
            # `/agents <id> --attach` mid-turn (Slice 3): the post-turn dispatch
            # acts on the {attach_agent:} signal, but during a turn the REPL is
            # blocked in #run_turn — so do the view switch HERE, on the reader
            # thread (clear + replay the sub + scope the prompt). attach_agent_view
            # suppresses the parent's painting; the parent turn keeps running.
            attach_agent_view(result[:attach_agent], Rubino.ui) if result.is_a?(Hash) && result[:attach_agent]
          end
          disposition
        rescue StandardError
          :pass
        end
      end

      # Tears down the composer: restores the real $stdout, flushes any held
      # partial line into scrollback, stops the reader and restores cooked mode.
      # Safe to call with nils (no composer was started).
      def stop_composer(composer, real_stdout)
        proxy = $stdout
        $stdout = real_stdout if real_stdout
        proxy.finish if proxy.respond_to?(:finish)
        # Preserve an un-submitted draft (text typed during the turn with no
        # Enter) before tearing the composer down; #next_input pre-fills the next
        # prompt with it. A submitted line clears the buffer, so this only ever
        # carries genuinely-pending input. An empty buffer leaves any prior draft
        # untouched so it survives queued steering turns in between.
        if composer
          draft = composer.buffer.to_s
          @pending_draft = draft unless draft.strip.empty?
        end
        composer&.stop
      rescue IOError, Errno::ENOTTY, Errno::EIO
        nil
      end

      # The leading `? ` ephemeral-probe trigger. Returns the side-question text
      # (everything after the `? `) when the line is a probe, nil otherwise. A
      # bare `?` or `?` with no following space is NOT a probe (so a real
      # message can start with `?` by typing it without the trailing space, or
      # by leading with a space per the escape rule in the UX doc).
      def probe_question(input)
        return nil unless input.start_with?("? ")

        q = input[2..].to_s.strip
        q.empty? ? nil : q
      end

      # Runs an ephemeral side-question against the live session and renders it
      # in the dim "probe (ephemeral · not saved)" aside, then DISCARDS it: the
      # Q&A never touches the session store, so the next real turn is unchanged.
      # The Q&A is stashed in @last_probe so a `/branch` right after can promote
      # it into the fork seed (the "actually, let's pursue this" move).
      def run_probe(runner, question, ui)
        # The probe is a synchronous side-inference with nothing streaming, so
        # the wait used to look frozen (#58): show the SAME thinking row a
        # normal turn gets, cleared before the aside (or failure) renders. TTY
        # only — never an indicator into a pipe.
        probe_thinking_started(ui)
        result = Interaction::Probe.new(
          session: runner.session,
          model_override: model_name,
          provider_override: opt(:provider)
        ).ask(question)
        probe_thinking_finished(ui)
        ui.probe_aside(result.answer)
        @last_probe = result
      rescue StandardError => e
        probe_thinking_finished(ui)
        # A probe is a throwaway aside — a failure must never break the REPL.
        ui.warning("probe failed: #{e.message}")
        @last_probe = nil
      end

      # Forks the current session at this point into a NEW saved session and
      # returns a runner switched into it (the REPL replaces its runner with
      # this). The original session is left untouched.
      #
      # Reuse: Session::Repository#create(parent_session_id:) sets the lineage
      # column, and Session::Store#copy_into seeds the child with the parent's
      # message history so far — the same context a resume would replay. When
      # the immediately-preceding interaction was a probe (@last_probe set), its
      # Q&A is appended to the seed too, so an aside that "never happened" in the
      # original becomes the branch's starting point.
      def branch_runner(ui, parent_runner, title)
        parent     = parent_runner.session
        store      = ::Rubino::Session::Store.new
        # Persist the parent if it was a lazily-built, never-saved session, so a
        # branch from a brand-new chat still inherits whatever is there and the
        # parent_session_id points at a real row.
        Session::Repository.new.persist!(parent) if parent[:persisted] == false

        # Mine the parent's un-mined tail BEFORE copying it into the child
        # (R2-M2). Compaction flushes before its copy; /branch did not, so a fact
        # in the parent's not-yet-extracted tail was copied across and then sealed
        # under the child's freshly-seeded cursor below — lost forever. Flushing
        # first pins the parent's cursor to its tail so the seed seals nothing.
        flush_parent_memory!(parent[:id])

        child = Session::Repository.new.create(
          source: "cli",
          model: parent[:model],
          provider: parent[:provider],
          title: title,
          parent_session_id: parent[:id],
          # A branch inherits the parent's launch dir so it resumes from the
          # same directory (r5 MF-4).
          cwd: parent[:cwd]
        )

        store.copy_into(child[:id], store.for_session(parent[:id]))
        included_probe = seed_probe_into!(store, child[:id])
        # Seed the memory-extraction watermark past the copied transcript (MEM-2)
        # so the branch's first turn extracts only NEW messages, not the whole
        # inherited history. Must run AFTER the probe seed so a promoted aside is
        # under the watermark too.
        store.seed_extraction_cursor(child[:id])
        # copy_into/seed write message rows but don't touch the session's cached
        # message_count, so sync it once here — otherwise /sessions shows the
        # inherited branch as "0 msgs" even though its transcript is populated.
        Session::Repository.new.update(child[:id], message_count: store.count(child[:id]))

        ui.branch_confirmation(
          new_id: child[:id],
          parent_id: parent[:id],
          title: title,
          included_probe: included_probe
        )

        @branch_short_id = child[:id][0..3]
        @last_probe = nil
        resume_runner(ui, child[:id])
      end

      # Mine the parent session's un-mined tail before a branch/rewind copies it
      # into a child (R2-M2). Mirrors what Compressor#flush_memory! does before a
      # compaction copy: routes through the configured backend so the parent's
      # extraction cursor lands on its tail and the child's subsequent seed seals
      # no un-mined fact. Gated on auto-extract (same predicate as the post-turn
      # job) and best-effort — a flush failure must never break the branch.
      def flush_parent_memory!(parent_id)
        return unless Rubino.configuration.memory_auto_extract?

        Memory::Flusher.new.flush_before_compaction!(parent_id)
      rescue SignalException, SystemExit, NoMemoryError, SystemStackError, SecurityError
        # Genuinely-fatal / control-flow exceptions (Ctrl+C, process exit, OOM,
        # stack overflow, a tripped security policy) MUST propagate — swallowing
        # them would wedge the process, not protect the branch.
        raise
      rescue Exception => e # rubocop:disable Lint/RescueException -- deliberate best-effort boundary: a memory-flush hiccup must NEVER break the rewind/branch (some transport errors, e.g. WebMock::NetConnectNotAllowedError, descend from Exception not StandardError and would otherwise escape)
        Rubino.logger.warn(event: "branch.parent_flush_failed", error: e.message)
        nil
      end

      # Appends the immediately-preceding probe's Q&A to the branch seed when one
      # is present (the user is promoting the aside). Returns true if a probe was
      # folded in, false otherwise.
      def seed_probe_into!(store, child_session_id) # rubocop:disable Naming/PredicateMethod -- a seeding mutator that reports what it did
        probe = @last_probe
        return false unless probe

        store.create(session_id: child_session_id, role: "user", content: probe.question)
        store.create(session_id: child_session_id, role: "assistant", content: probe.answer)
        true
      end

      # --- Esc-Esc rewind (edit-and-resend) -----------------------------------
      #
      # Double-Esc at the idle prompt walks back through the session's USER
      # messages: a picker (the same arrow-key machinery /sessions uses, Esc
      # cancels) lists them most recent first; picking one FORKS the session at
      # the point BEFORE that message (the /branch copy-truncated infra), parks
      # the fork's runner for the REPL to adopt, and pre-fills the composer
      # with the message text ready to edit — Enter sends it as the next turn
      # on the fork. The original session is never touched.

      # Run the rewind flow. Returns the fork's runner on a pick, nil on
      # cancel / nothing to rewind to. Must run OFF the composer's reader
      # thread: ui.select suspends the composer (run_in_terminal), which joins
      # that thread.
      def handle_rewind(composer, runner, ui)
        messages = ::Rubino::Session::Store.new.for_session(runner.session[:id])
        user_idx = messages.each_index.select { |i| rewindable_message?(messages[i]) }
        if user_idx.empty?
          composer.announce("(no earlier message to rewind to)")
          return nil
        end

        choices = user_idx.reverse.map { |i| [rewind_choice_label(messages[i]), i] }
        chosen  = ui.select("Rewind to which message? (Esc to cancel)", choices)
        return nil if chosen.nil?

        rewind_onto_fork(composer, runner, ui, messages, chosen,
                         ordinal: user_idx.index(chosen) + 1)
      end

      # Fork the session at the picked message and switch onto it: seed the
      # child with everything BEFORE the message (copy-truncated), adopt the
      # fork's runner + status bar, print the dim note, and pre-fill the
      # composer with the message text (multiline-safe) for edit-and-resend.
      def rewind_onto_fork(composer, runner, ui, messages, index, ordinal:)
        child      = rewind_fork(runner, messages.first(index))
        # The rewind has its own "┄ rewound to message N — editing ┄" marker, so
        # suppress the generic "Resuming session: <id>…" plumbing line the runner
        # would otherwise emit on the fork switch (#220).
        new_runner = build_runner(session_id: child[:id], ui: ui, announce_session: false)
        @branch_short_id = child[:id][0..3]
        ui.note("rewound to message #{ordinal} — editing")
        composer.set_status(build_status_line(new_runner))
        composer.prefill(messages[index].content)
        new_runner
      end

      # A row the rewind picker offers: a REAL typed user message — not a tool
      # result riding the user role, and not the `!` bang-shell injections
      # (<bash-input>/<bash-stdout> context glue is not something to resend).
      def rewindable_message?(msg)
        msg.role == "user" && msg.tool_call_id.nil? &&
          !msg.content.to_s.start_with?("<bash-")
      end

      # One picker row: `N ago · <first 60 chars>` — recency + a flattened
      # snippet, enough to recognize the turn at a glance.
      def rewind_choice_label(msg)
        snippet = msg.content.to_s.gsub(/\s+/, " ").strip
        snippet = "#{snippet[0, REWIND_SNIPPET_CHARS]}…" if snippet.length > REWIND_SNIPPET_CHARS
        age = message_age(msg)
        age ? "#{age} · #{snippet}" : snippet
      end

      # "5m ago" for a message row (same humanization as the /sessions picker);
      # nil when the timestamp is unparseable — the row renders without it.
      def message_age(msg)
        created = msg.created_at
        created = Time.parse(created.to_s) unless created.is_a?(Time)
        "#{Rubino::Util::Duration.human_duration(Time.now - created)} ago"
      rescue StandardError
        nil
      end

      # The copy-truncated fork (the /branch infra, cut at the rewind point):
      # a child session with lineage set, seeded with +seed_messages+ — every
      # message BEFORE the picked one — leaving the original untouched.
      def rewind_fork(runner, seed_messages)
        parent = runner.session
        repo   = Session::Repository.new
        # Persist a lazily-built, never-saved parent first, exactly as /branch
        # does, so parent_session_id points at a real row.
        repo.persist!(parent) if parent[:persisted] == false

        child = repo.create(
          source: "cli",
          model: parent[:model],
          provider: parent[:provider],
          title: nil,
          parent_session_id: parent[:id],
          # A rewind-fork inherits the parent's launch dir (r5 MF-4).
          cwd: parent[:cwd]
        )
        store = ::Rubino::Session::Store.new
        # Mine the parent's un-mined tail before the (truncated) copy, same as
        # /branch (R2-M2): otherwise a fact in a copied-but-not-yet-extracted
        # message is sealed under the child's seeded cursor below and lost.
        flush_parent_memory!(parent[:id])
        store.copy_into(child[:id], seed_messages)
        # Seed the memory-extraction watermark past the copied transcript (MEM-2)
        # so the rewind fork's first turn extracts only the edited/new message,
        # not the whole inherited history.
        store.seed_extraction_cursor(child[:id])
        # copy_into writes message rows but not the cached message_count —
        # sync it once, same as /branch (#/sessions would show "0 msgs").
        repo.update(child[:id], message_count: store.count(child[:id]))
        child
      end

      # The Ctrl+O callback for the composer: reveal the last retained reasoning
      # aside via the UI adapter (the CLI keeps the buffer). The reveal commits
      # through the composer's serialized print_above, so it lands cleanly above
      # the prompt idle OR mid-turn. nil when the adapter can't reveal, so the
      # composer treats Ctrl+O as a no-op.
      def ctrl_o_handler
        ui = Rubino.ui
        return nil unless ui.respond_to?(:reveal_last_reasoning)

        -> { ui.reveal_last_reasoning }
      end

      # The Shift+Tab callback for the composer: cycle the mode to the next in
      # Modes::ALL (default→plan→yolo→default), PERSIST it via Modes.set, show
      # the transition toast, and RETURN the freshly-built STATUS-BAR line so
      # the composer updates the mode token LIVE (the mode lives in the status
      # bar now, not in a prompt chip). +runner+ feeds the bar's model/context
      # numbers. The composer holds no mode logic — it just adopts the
      # returned status line.
      def mode_cycle_handler(runner)
        -> { cycle_mode(runner) }
      end

      # --- primary-agent switching (#320) ------------------------------------

      # The Tab callback for the composer: cycle to the next PRIMARY agent
      # (Rubino::ActiveAgent), show a transient toast, and RETURN the freshly
      # built status-bar line so the agent chip updates LIVE — same shape as
      # #mode_cycle_handler. Only fires when there's nothing to complete (the
      # composer routes a buffer-empty / menu-closed Tab here), so file/command
      # completion is untouched.
      def agent_cycle_handler(runner)
        -> { cycle_agent(runner) }
      end

      # Tab: cycle the active primary agent, toast the transition, and return the
      # refreshed status-bar line (the agent chip lives in the bar). With a
      # single primary agent it's a no-op (no toast, no repaint).
      def cycle_agent(runner = nil)
        names = Rubino::ActiveAgent.names
        return nil if names.size < 2

        previous = Rubino::ActiveAgent.current
        nxt      = Rubino::ActiveAgent.cycle
        runner.agent_definition = Rubino::ActiveAgent.definition if runner.respond_to?(:agent_definition=)
        desc = Rubino.agent_registry.find(nxt)&.description.to_s
        show_mode_footer("┄ agent #{previous} → #{nxt} — #{desc}, tab to cycle ┄")
        build_status_line(runner)
      end

      # Applies a sticky `/agent <name>` switch: pin the slot (the status-bar
      # source of truth), retarget the live runner so the NEXT turn runs under
      # the new Definition, and confirm. An unknown/non-primary name is rejected
      # by ActiveAgent.set; we surface it instead of crashing the REPL.
      def switch_primary_agent(name, runner, ui)
        previous = Rubino::ActiveAgent.current
        Rubino::ActiveAgent.set(name)
        runner.agent_definition = Rubino::ActiveAgent.definition if runner.respond_to?(:agent_definition=)
        ui.success("agent: #{previous} → #{Rubino::ActiveAgent.current}")
        # A /agent switch is NON-destructive: the REPL, the session, and the
        # subagent registry all stay alive, so we must NOT cancel running
        # children (that would kill useful in-flight work). But a child blocked on
        # ask_parent is now waiting on a parent the human just re-pinned, which is
        # easy to forget — so SURFACE any blocked child (the safe behavior here)
        # rather than leave it stuck invisibly. The human can still /reply it.
        warn_blocked_children_after_switch(ui)
      rescue ArgumentError => e
        ui.error(e.message)
      end

      # After a /agent switch, remind the human of any subagent still blocked on
      # an ask_parent question (waiting on the human OR on its agent-parent) so
      # the switch never silently strands a parked child at the idle prompt. Pure
      # surfacing — nothing is cancelled; the children keep running and stay
      # answerable via /reply <id>. Best-effort and quiet when nothing is blocked.
      def warn_blocked_children_after_switch(ui)
        blocked = Tools::BackgroundTasks.instance.running.select do |e|
          %i[blocked_on_human blocked_on_parent].include?(e.status)
        end
        return if blocked.empty?

        ui.warning("#{blocked.size} subagent(s) still waiting on an answer — /reply <id> to answer:")
        blocked.each { |e| ui.info("  #{e.id} · #{e.subagent}") }
      rescue StandardError
        nil
      end

      # Resolves a one-shot `/<agent> <message>` route to its Definition, or nil
      # when no agent was named (the plain-turn path). An unknown name degrades
      # to nil (the turn runs under the sticky agent) rather than crashing.
      def one_shot_agent_definition(agent_name)
        return nil if agent_name.nil? || agent_name.to_s.strip.empty?

        Rubino.agent_registry.find(agent_name.to_s.strip)
      end

      # Shift+Tab: cycle the mode, show a SINGLE TRANSIENT confirmation banner,
      # and RETURN the freshly-built status-bar line so the composer redraws the
      # mode token LIVE (fixes the stale-chip D7). The persistent indicator is
      # the STATUS BAR's leading mode token; the banner is a one-shot toast
      # rendered in the composer's live region via #announce — redrawn in place,
      # cleared on the next keystroke, NEVER committed to scrollback. So cycling
      # N times leaves ZERO stacked banner lines (D3) and a mid-stream Shift+Tab
      # can't wedge a banner between answer chunks (D2). With no composer
      # (cooked fallback) it falls back to a plain dim line.
      #
      # Entering YOLO from the cycle is gated behind a second press (#152):
      # the press that lands on yolo only ARMS it and shows a confirm toast;
      # blind mashing past plan can no longer silently drop the approval gates
      # of the session AND its running background children. An explicit
      # `/mode yolo` stays direct.
      def cycle_mode(runner = nil)
        previous = Rubino::Modes.current
        idx      = Rubino::Modes::ALL.index(previous) || 0
        nxt      = Rubino::Modes::ALL[(idx + 1) % Rubino::Modes::ALL.length]
        return announce_yolo_confirm if nxt == Rubino::Modes::YOLO && !yolo_cycle_confirmed?

        @yolo_armed_at = nil
        Rubino::Modes.set(nxt)
        # Same `<old> → <new>` arrow grammar as the /mode footer (#78), plus
        # the description and the cycle hint only this transient toast carries.
        show_mode_footer("┄ mode #{previous} → #{nxt} — #{Rubino::Modes.description(nxt)}, shift+tab to cycle ┄")
        build_status_line(runner)
      end

      # True when THIS Shift+Tab press is the deliberate second press that
      # confirms entering yolo. Anything else (first press, mash, stale arm)
      # (re-)arms and returns false.
      def yolo_cycle_confirmed?
        now     = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = @yolo_armed_at ? now - @yolo_armed_at : nil
        return true if elapsed&.between?(YOLO_CONFIRM_MIN_SECONDS, YOLO_CONFIRM_WINDOW_SECONDS)

        @yolo_armed_at = now
        false
      end

      # The arm toast: says what yolo will do — including to RUNNING background
      # children, whose gates drop the moment the mode flips — and how to
      # confirm. Returns nil (the mode did not change ⇒ no status-bar update).
      def announce_yolo_confirm
        live = Tools::BackgroundTasks.instance.running.size
        children = live.positive? ? " — #{live} running subagent(s) will run gated actions unprompted" : ""
        show_mode_footer("┄ yolo skips ALL approvals#{children} — press shift+tab again to confirm ┄")
        nil
      end

      # Routes a transient mode footer through the live composer's #announce
      # (never committed to scrollback, D2/D3) or, with no composer (cooked
      # fallback), prints a plain dim line.
      def show_mode_footer(text)
        footer   = pastel.dim(text)
        composer = UI::BottomComposer.current
        if composer
          composer.announce(footer)
        else
          $stdout.print "\n#{footer}\n"
          $stdout.flush
        end
      end

      # The clean Rail-rubino prompt: a bare "❯ " caret. The mode/branch/skill
      # chip that used to lead it lives in the STATUS BAR now (see
      # #build_status_line / UI::StatusBar) — the composer prepends the red
      # rail itself (#composer_rail), so committed echoes built from this
      # ("❯ <line>") stay rail-free in scrollback.
      def build_prompt
        # While attached to a subagent the prompt is SCOPED to it, so the next
        # idle composer signals "you're talking to this agent" (the input steers
        # /answers it, never runs a parent turn). build_prompt is the single place
        # the idle composer's label comes from, so the scope rides every rebuild.
        return "#{@attached_id} #{PROMPT_CARET} " if @attached_id

        "#{PROMPT_CARET} "
      end

      # The one-column brand rail (the red ▍ glyph) the composer draws as
      # the first column of EVERY input row — first row and continuations.
      # Pastel auto-disables color off a TTY, and the composer itself only
      # runs on a real TTY, so the rail never reaches piped output.
      def composer_rail
        pastel.red(PROMPT_RAIL)
      end

      def pastel
        @pastel ||= Pastel.new
      end

      def collapse_home(path)
        home = Dir.home
        path.start_with?(home) ? path.sub(home, "~") : path
      rescue ArgumentError
        path
      end

      # Best-effort git status. Returns nil outside a checkout. Shells out
      # because we're already paying a readline-roundtrip on every prompt —
      # 3 git commands at ~5ms each is invisible against that.
      def git_context
        return nil unless system("git rev-parse --is-inside-work-tree > /dev/null 2>&1")

        branch = `git branch --show-current 2>/dev/null`.strip
        sha    = `git rev-parse --short HEAD 2>/dev/null`.strip
        dirty  = !`git status --porcelain 2>/dev/null`.strip.empty?
        return nil if branch.empty? && sha.empty?

        { branch: branch.empty? ? "(detached)" : branch, sha: sha, dirty: dirty }
      end

      # --- Helpers ---

      def opt(key)
        @options[key] || @options[key.to_s]
      end

      # --quiet / -Q: silence the default-on stderr tool-activity trace in the
      # one-shot TEXT path (answer-only on stdout, nothing on stderr) — the
      # machine-silent path. NOTE: `-q` is `--query` (the prompt CONTENT), not
      # quiet; the silencing flag is the CAPITAL -Q, mirroring Hermes' -q/-Q.
      def quiet?
        opt(:quiet) == true
      end

      # --verbose / -v: widen the per-tool trace hint (fuller args), mirroring
      # Claude's --verbose. No effect under --quiet (the trace is off).
      def verbose?
        opt(:verbose) == true
      end

      # Reads the one-shot prompt from $stdin when it's piped/redirected (#329c).
      # Returns the whole stdin body (so a multi-line heredoc/file becomes one
      # prompt), or nil when stdin is a TTY (interactive — never block waiting on
      # a human to type) or on any read error. Best-effort: a stdin hiccup must
      # never crash the launch.
      def read_piped_prompt
        return nil if $stdin.respond_to?(:tty?) && $stdin.tty?

        body = $stdin.read
        body unless body.nil? || body.empty?
      rescue StandardError
        nil
      end

      # Seeds extra workspace roots from --add-dir and runs the folder-trust
      # gate for the primary root and each added dir, BEFORE any turn assembles
      # a system prompt (so an untrusted dir's AGENTS.md/skills are withheld).
      # +interactive+ false (one-shot/-q) skips the prompt entirely.
      def setup_workspace_and_trust!(ui, interactive:)
        gate = TrustGate.new(ui: ui, interactive: interactive, ignore_rules: opt(:ignore_rules) || false)

        # Primary root first — the dir rubino was launched in.
        gate.ensure_trust(Rubino::Workspace.primary_root)

        Array(opt(:add_dir)).each do |dir|
          real = Rubino::Workspace.add(dir)
          # In one-shot/headless mode the stdout answer must stay pipe-clean
          # (#418): a `--add-dir` status/error notice belongs on STDERR there, so
          # `x=$(rubino prompt …)` doesn't capture "added workspace …" or
          # "--add-dir <missing>: …" alongside the answer. Interactive keeps the
          # styled ui notice. F6.
          dir_notice(ui, "added workspace #{collapse_home(real)}", interactive: interactive)
          gate.ensure_trust(real)
        rescue ArgumentError => e
          dir_notice(ui, "--add-dir #{dir}: #{e.message}", interactive: interactive, error: true)
        end
      end

      # Emits a --add-dir status/error notice on the right stream: the styled ui
      # method when interactive, plain STDERR when headless (#418/F6) so the
      # piped stdout answer stays clean.
      def dir_notice(ui, message, interactive:, error: false)
        if interactive
          if error
            ui.error(message) if ui.respond_to?(:error)
          elsif ui.respond_to?(:status)
            ui.status(message)
          end
        else
          warn(error ? "rubino: #{message}" : message)
        end
      end

      def model_name
        opt(:model) || opt(:m) || Rubino.configuration.dig("model", "default")
      end

      def model_override_given?
        !!(opt(:model) || opt(:m))
      end

      # Echoes the effective model in one-shot mode and warns on an unknown id
      # (#142). The warning + echo go to stderr so the answer on stdout stays
      # clean for piping. Only fires for an explicit `-m`/`--model` override so
      # the default-model happy path is unchanged.
      def announce_resolved_model
        return unless model_override_given?

        warn "model: #{model_name}"
        warn_unknown_model
      end

      # When the resolved model id isn't in the known catalog, print a clear
      # stderr warning — then PROCEED (assume-exists providers like MiniMax pass
      # arbitrary ids through deliberately), so a typo no longer becomes a silent
      # wrong-model run (#142).
      def warn_unknown_model
        id = model_name
        return if id.nil? || id.to_s.empty?
        return if model_known?(id)

        warn "rubino: warning: model '#{id}' is not in the known model catalog " \
             "(accepted unverified; a typo here will hit the provider as-is)."
      end

      # A headless `--resume <id>` that LOSES the concurrent-claim race is
      # silently re-routed to a FORK (the Runner copies history into a fresh
      # session so two writers never interleave). The Runner's status line for
      # that fork is gated on @announce_session — OFF headless — so a pipeline
      # had no way to tell its resume wrote to a DIFFERENT session than it asked
      # for (#420). Detect the re-route here (a forked child carries
      # parent_session_id and a new id) and emit a one-line STDERR notice — off
      # the clean stdout answer, mirroring the other headless diagnostics.
      def warn_if_resume_forked(requested_session_id, runner)
        return if requested_session_id.nil?

        session = runner.session
        return unless session && session[:parent_session_id]
        return if session[:id] == requested_session_id

        warn "rubino: session #{requested_session_id.to_s[0, 8]} is in use by another " \
             "rubino — resumed a forked copy: #{session[:id].to_s[0, 8]}"
      end

      # An EXPLICIT `--resume <id>` of a session that was later COMPACTED resumes
      # the literal un-compacted parent (status "compacted") — intentional, since
      # an explicit id means "this exact session". But a compacted continuation
      # (a child carrying the summarised context) exists, and the user got no
      # hint of it (#501). Print a note that the original was compacted and how
      # to pick up the continuation instead; do NOT change which session loads.
      # Only fires for explicit --resume (not --continue / auto-resume, which
      # already land on the freshest resumable row) and only when the resolved
      # session is itself a compacted parent. +ui+ surfaces it inline for the
      # interactive REPL; the headless paths pass nil and it goes to STDERR,
      # mirroring warn_if_resume_forked.
      def note_if_resuming_compacted_parent(runner, ui: nil)
        return unless opt(:resume) || opt(:r)

        session = runner.session
        return unless session && session[:status].to_s == "compacted"

        msg = "session #{session[:id].to_s[0, 8]} was compacted — resuming the " \
              "original; use --continue for the compacted continuation."
        ui ? ui.info(msg) : warn("rubino: #{msg}")
      end

      # Pre-flight existence check for an EXPLICIT --resume/-r/--session/-s id,
      # run BEFORE the boot banner so a bad id errors cleanly with no misleading
      # banner (#resume-banner-order). Mirrors the runner's own lookup
      # (find_by_id_or_title) and raises the SAME SessionError when the id is
      # unknown — the #chat rescue turns it into a stderr line + exit 1. A
      # KNOWN id (or any non-explicit path: --continue / bare-chat auto-resume)
      # is a no-op, so build_runner stays the authoritative resume and the happy
      # path is unchanged. Best-effort: a repository hiccup falls through to the
      # normal path rather than blocking a valid resume.
      def validate_explicit_resume!
        id = opt(:session) || opt(:resume) || opt(:r)
        return if id.nil? || id.to_s.strip.empty?

        return if Session::Repository.new.find_by_id_or_title(id)

        raise Rubino::SessionError,
              "Session not found: #{id}. " \
              "Try `rubino sessions list`, or resume by id prefix."
      rescue Rubino::SessionError
        raise
      rescue StandardError
        nil
      end

      # True when the model id resolves in ruby_llm's registry. A fake/* id (the
      # dev FakeProvider) is always treated as known so it never triggers the
      # warning. Any registry hiccup is treated as "known" so we never block on a
      # cosmetic check.
      def model_known?(id)
        return true if id.to_s.start_with?("fake/") || opt(:provider).to_s == "fake"

        !RubyLLM.models.find(id).nil?
      rescue RubyLLM::ModelNotFoundError
        false
      rescue StandardError
        # A registry-load hiccup must not produce a false "unknown" warning;
        # treat it as known and let the provider be the source of truth.
        true
      end

      # The `--max-turns N` flag, threaded into the runner so it actually caps
      # per-turn tool iterations (#141). Thor delivers a numeric as a Float;
      # the IterationBudget coerces/validates it (0/blank ⇒ use config default).
      def max_turns_override
        opt(:max_turns) || opt(:"max-turns")
      end

      # Builds an Agent::Runner with this invocation's shared flag overrides —
      # only the session and UI vary per call site (one-shot, interactive boot,
      # /sessions resume, /new).
      def build_runner(session_id:, ui:, announce_session: true)
        Agent::Runner.new(
          session_id: session_id,
          model_override: model_name,
          provider_override: opt(:provider),
          max_turns: max_turns_override,
          ignore_rules: opt(:ignore_rules) || false,
          ui: ui,
          announce_session: announce_session
        )
      end

      # Rebuilds the runner on a chosen session (the /sessions in-chat resume)
      # and replays its history so the transcript matches what was there before.
      def resume_runner(ui, session_id)
        runner = build_runner(session_id: session_id, ui: ui)
        session_resolver.print_session_history(ui, runner.session[:id])
        runner
      end

      # Builds a runner on a brand-new session (the in-chat `/new`), without
      # passing any session_id so the runner creates a fresh one.
      def fresh_runner(ui)
        build_runner(session_id: nil, ui: ui)
      end

      # --- agent-attach view (timeline switch + scoped input) ------------------

      # True while the prompt is scoped to a background subagent: the on-screen
      # timeline IS that agent's and typed input steers/answers it.
      def attached_to_agent?
        !@attached_id.nil?
      end

      # Switch the view to a background subagent: clear the screen and replay ITS
      # OWN full transcript (each child runs its own runner+session), then scope
      # the prompt to it (build_prompt picks up @attached_id on the next idle
      # composer). This replaces the bounded registry snapshot the old `/agents
      # <id>` drill-in showed with the agent's REAL conversation — its tool calls
      # and what it said.
      def attach_agent_view(id, ui)
        entry = Tools::BackgroundTasks.instance.find(id)
        return ui.error("no background subagent with id #{id}") unless entry

        @attached_id = id
        # Focus-gate the parent: while attached, a still-running parent turn
        # keeps streaming to its session but must NOT paint this sub's screen.
        # Set suppression BEFORE the replay so the parent's frames drop straight
        # away; the replay itself renders through the exempt seam below. No-op off
        # a composer (plain TTY / pipe / tests).
        composer = UI::BottomComposer.current
        composer&.suppress_main_render!(true)
        clear_terminal
        with_focused_view_replay(composer) do
          ui.info(pastel.cyan("▶ attached to #{id} · #{entry.subagent}") +
                  pastel.dim(" — type to steer · ← to go back"))
          session_resolver.replay_messages(ui, entry.messages)
        end
      end

      # Leave the agent-view and return to the main session: clear the screen,
      # replay the main timeline, drop the scope (build_prompt returns the default
      # ❯ again on the next idle composer).
      def detach_agent_view(runner, ui)
        @attached_id = nil
        clear_terminal
        # Rebuild the main view from its full session — this captures everything
        # the parent turn streamed WHILE we were away (it kept persisting). Render
        # it through the exempt seam (suppression is still on here), THEN lift
        # suppression so a still-running parent turn paints normally again from
        # its next frame.
        composer = UI::BottomComposer.current
        with_focused_view_replay(composer) do
          ui.info(pastel.dim("◀ back to the main session"))
          session_resolver.replay_session(ui, runner.session[:id])
        end
        composer&.suppress_main_render!(false)
      end

      # Render the attach/detach REPLAY (the focused view the user is meant to
      # see) through the composer's replay-exempt seam, so it paints even while
      # main-render is suppressed. Yields plainly when no composer owns the screen
      # (plain TTY / pipe / tests) — there is nothing to suppress there.
      def with_focused_view_replay(composer, &)
        return yield unless composer

        composer.with_replay_exempt(&)
      end

      # Adopt a new runner for the REPL and rebuild the command executor against
      # it in ONE place. Every branch that swaps the live runner (rewind, /branch,
      # /sessions, /compact, /new, plus the initial build) routes through here, so
      # the "runner changed → executor must follow" invariant can't be forgotten
      # by a future branch and leave a stale executor wired to the old runner.
      # Returns the new runner so callers can write `runner = swap_runner!(...)`.
      def swap_runner!(new_runner, ui)
        @cmd_executor = Rubino::Commands::Executor.new(ui: ui, runner: new_runner)
        new_runner
      end

      # Route a line typed while attached. `/detach` (or the child being gone)
      # returns to the main view; a `/`-line is an agent-scoped command; plain
      # text answers a blocked child or steers a running one. Everything reuses
      # the existing /agents + /reply handlers via the executor, so no new command
      # surface is introduced — it just makes the global `/agents <id> ...` forms
      # redundant inside this view.
      def handle_attached_input(input, runner, ui, cmd_executor)
        id    = @attached_id
        entry = Tools::BackgroundTasks.instance.find(id)

        # The child's entry is GONE (reaped) while attached: nothing to show —
        # fall back to the main view so the user is never stranded on a dead scope.
        return detach_agent_view(runner, ui) if entry.nil?

        # The child reached a TERMINAL state (completed/failed/stopped) WHILE you're
        # attached: its entry still exists (so you keep its final snapshot on
        # screen), but it can no longer be steered/answered. DON'T route typed text
        # to steer — that returned the alarming "✗ cannot steer <id> — no such
        # running subagent (subagents reset when rubino restarts)" and left the
        # prompt wedged on a dead scope (the user's "forced to restart" report).
        # Switching to another live subagent still works; anything else gets a calm
        # notice — ← / /back returns to main. (Live = the same set BackgroundTasks#
        # live_status? / AgentMenu#live? use; inlined since it's the only use here.)
        unless %i[running needs_approval blocked_on_human blocked_on_parent stopping].include?(entry.status)
          return attach_agent_view(Regexp.last_match(1), ui) if input =~ %r{\A/agents\s+(\S+)\s+--attach\z}

          ui.info(pastel.dim("◦ #{id} has finished · #{entry.status} — press ← or /back to return to main"))
          return
        end

        # Call the agent handlers DIRECTLY with the raw text (not by serializing a
        # `/agents <id> steer "…"` string and re-parsing it through the executor,
        # which whitespace-splits + single-pair dequotes and so mangles any note
        # containing a quote). /stop carries no free text, so its command form is
        # fine.
        case input
        when "/stop"
          cmd_executor.try_execute("/agents #{id} --stop")
        when %r{\A/agents\s+(\S+)\s+--attach\z}
          # The picker is a switcher while attached: selecting another subagent
          # SWITCHES the view to it (re-clear + replay) rather than steering.
          attach_agent_view(Regexp.last_match(1), ui)
        when %r{\A/(?:reply|answer)\s+(.+)\z}m
          agents_request_handler.deliver_reply(entry, Regexp.last_match(1))
        when %r{\A/probe\s+(.+)\z}m
          agents_request_handler.probe_agent(id, Regexp.last_match(1))
        else
          if %i[needs_approval blocked_on_human].include?(entry.status)
            # The child is blocked on YOU → the line is the answer.
            agents_request_handler.deliver_reply(entry, input)
          else
            # The child is running → the line is a steer note folded at its next turn.
            agents_request_handler.steer_agent(id, input)
          end
        end
      end

      # Hard screen clear (clear + scrollback + home) for the attach/detach view
      # switch — the "whole timeline changes" effect. Printed straight to the real
      # terminal: the idle composer is torn down between reads, so $stdout is the
      # bare TTY here (the same point resume_runner replays into).
      def clear_terminal
        $stdout.print("\e[2J\e[3J\e[H")
        $stdout.flush
      end

      # Resolves the yolo (skip-all-approvals) mode for this invocation (#260).
      #
      # yolo is the explicit, full-auto opt-in, so — like Gemini CLI — it may be
      # granted ONLY by the `--yolo` CLI flag, never by a persisted/untrusted
      # config file. The flag value reaches us through Thor's parsed options
      # (opt(:yolo)), which only carries the command-line flag — a project-local
      # config.yml cannot set it, so a malicious repo can't auto-grant itself
      # auto-exec just by sitting in the working directory.
      #
      #   --yolo     → true  → enable yolo (auto-approve everything this run)
      #   --no-yolo  → false → FORCE fail-closed, overriding any yolo default
      #                        (e.g. a RUBINO_BOOT_MODE=yolo the boot picked up)
      #   (absent)   → nil   → leave the boot mode untouched (default/plan)
      #
      # `--yolo` is the CLI flag form of `/mode yolo`; both route through
      # Rubino::Modes so the status bar token, the API event and the
      # ApprovalPolicy short-circuit share one source of truth.
      def resolve_yolo!
        flag = opt(:yolo)
        if flag == true
          Rubino::Modes.set(:yolo)
        elsif flag == false && Rubino::Modes.current == :yolo
          # Explicit --no-yolo wins over a yolo default so fail-closed is real.
          Rubino::Modes.set(:default)
        end
      end

      def ensure_setup!
        ensure_database_ready!

        # Same opt-in gate as ServerCommand: fake provider is dev-only and
        # must not be reachable without RUBINO_ALLOW_FAKE=1.
        if Rubino.configuration.dig("model", "provider").to_s == "fake" &&
           ENV["RUBINO_ALLOW_FAKE"] != "1"
          warn "fake provider is dev-only — set RUBINO_ALLOW_FAKE=1 to opt in."
          exit(1)
        end

        # Without this the tool registry stays empty, Lifecycle#load_tools
        # returns [], no `tools: [...]` is sent on the wire, and the model
        # has no choice but to roleplay bash in markdown. Symptom verified
        # via RUBYLLM_DEBUG=1 — request body was missing `tools` entirely.
        # Gate on a missing CORE tool, not on emptiness: a partially-populated
        # registry (e.g. only "shell" left behind) must still get the defaults
        # re-registered — #register is idempotent by name and never touches
        # MCP-prefixed wrappers.
        Rubino::Tools::Registry.register_defaults! unless Rubino::Tools::Registry.find("write")

        # MCP is experimental and opt-in: a configured `mcp.servers` block
        # connects the servers and registers their prefixed tools alongside
        # the built-ins (#91). Best-effort — boot! warns and returns nil on
        # failure, it never blocks chat.
        Rubino::MCP.boot!

        # Instantiate the shared agent registry at boot so the `task` tool can
        # resolve subagents (explore/general) in chat — same delegation flow as
        # the API path. Memoized on Rubino.agent_registry.
        Rubino.agent_registry
      end

      # First-run credential gate (#93). Before any model call, check the
      # resolved provider actually has a usable key. If it does, do nothing —
      # an already-configured user is unaffected. If it doesn't:
      #   • interactive TTY → run the onboarding wizard so the user picks a
      #     provider/model and pastes a key; bail out if they decline.
      #   • non-interactive (-q / piped / no TTY) → print the clear, actionable
      #     guidance to stderr and exit non-zero, instead of dropping into an
      #     ~80s silent-retry storm that exits 0 empty.
      # An explicit --model/--provider override or RUBINO_ALLOW_FAKE bypasses
      # this gate (the user is steering deliberately).
      def ensure_model_configured!
        # An explicit --model/--provider means the user is steering deliberately
        # (e.g. fake provider, a local model, a per-invocation override): skip the
        # config-based preflight and let the runtime classifier fail fast on a
        # real missing credential. The preflight only guards the DEFAULT path.
        return if opt(:model) || opt(:m) || opt(:provider)
        return if LLM::CredentialCheck.usable?

        if interactive_setup_possible?
          ok = OnboardingWizard.new(ui: Rubino.ui).run
          # Re-check: the wizard wrote config/.env in this process. If the user
          # skipped or it still isn't usable, fall through to the guidance/exit.
          return if ok && LLM::CredentialCheck.usable?
        end

        warn LLM::CredentialCheck.missing_key_message
        emit_preflight_error(LLM::CredentialCheck.missing_key_message)
        exit(1)
      end

      # Emits the #327 error envelope on stdout for a PREFLIGHT failure (missing
      # credential) when running under --output-format json|stream-json
      # (STRUCT-F2). The default path's preflight `exit(1)` wrote a good stderr
      # message but ZERO bytes on stdout, breaking the json/stream-json contract
      # that EVERY headless run yields a parseable result object on stdout (the
      # -m/--provider override path already emits one via the run! error rescue —
      # this just makes the credential preflight format-aware too). A text/no-TTY
      # run keeps the stderr-only behaviour. For stream-json the result line is
      # itself valid JSONL (a single object), so no system/init frame is needed.
      def emit_preflight_error(message)
        return unless json_mode?

        emit_json(Output::ResultSerializer.arg_error(
                    message: message, subtype: "error_missing_credential",
                    model: model_name
                  ))
      rescue StandardError
        # Never let the envelope emission mask the real exit(1) below.
        nil
      end

      # Onboarding is only meaningful when we can actually prompt the user: both
      # ends a real TTY, and not a one-shot/scripted invocation.
      def interactive_setup_possible?
        return false if opt(:query) || opt(:q)

        $stdin.tty? && $stdout.tty?
      rescue StandardError
        false
      end

      # Bare words that end the session. Beyond the obvious exit/quit/bye we
      # honour the vim/less reflexes — `q`, `:q`, `:wq`, `:quit` — that a dev
      # types on muscle memory; otherwise they'd burn an LLM turn (and have
      # weirdly made the model load skills). Cheap to recognize, saves a turn.
      def exit_command?(input)
        %w[exit quit bye /exit /quit q :q :wq :quit].include?(input.strip.downcase)
      end

      # Maps a bare `help` / `commands` / `?` (typed alone) onto its slash
      # command so it shows the help/commands listing instead of becoming an
      # LLM turn. Anything else passes through untouched.
      def help_alias_to_command(input)
        case input.strip.downcase
        when "help", "?" then "/help"
        when "commands"  then "/commands"
        else input
        end
      end

      # Background subagents die with the process (nothing is persisted), so a
      # /quit with live children must not be silent (#154): list them and
      # confirm, default No. Off a real terminal there is no one to ask — the
      # listed warning becomes the clear kill notice and the exit proceeds.
      def confirm_quit?(ui)
        live = Rubino::Tools::BackgroundTasks.instance.running
        return true if live.empty?

        n = live.size
        ui.warning("#{n} background subagent#{"s" if n != 1} still running — quitting stops " \
                   "#{n == 1 ? "it" : "them"} (partial side effects may remain):")
        live.each { |e| ui.info("  #{e.id} · #{e.subagent} · #{e.status}") }
        return true unless ui.respond_to?(:interactive_terminal?) && ui.interactive_terminal?

        answer = ui.ask("quit anyway? [y/N] ")
        %w[y yes].include?(answer.to_s.strip.downcase)
      end

      # First-run guard. A brand-new user who runs `chat` before `setup` used
      # to hit a raw `SQLite3::SQLException: no such table: sessions` stack
      # trace: `database.healthy?` only runs `SELECT 1`, which succeeds the
      # moment SQLite lazily creates an empty file — the schema is still
      # missing (F2). Detect the un-migrated DB and auto-initialize (create the
      # home dirs + run migrations); migrations are idempotent, so this is safe
      # to run every boot. Only fall back to a friendly "run setup" message if
      # the auto-init itself fails, never a Ruby backtrace.
      def ensure_database_ready!
        # A corrupt-but-PRESENT DB is NOT an un-setup install (#359): the file
        # exists, its image is just malformed, so `ensure_database_ready!` fails
        # (the migrate touch raises CorruptException) and the old message
        # misleadingly told the user to run `rubino setup` as if nothing was
        # there. Route corruption to the doctor diagnostic instead — mirroring
        # the guarded path `sessions list` uses (#333) — so the user is pointed
        # at recovery, not first-run setup.
        if Rubino.database.corrupt?
          warn "rubino database is corrupt (malformed image) — run `rubino doctor`."
          exit(1)
        end

        return if Rubino.ensure_database_ready!

        warn "rubino isn't set up yet — run `rubino setup` first."
        exit(1)
      end
    end
  end
end
