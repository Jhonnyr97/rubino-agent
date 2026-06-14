# frozen_string_literal: true

require "pastel"
require "io/console"

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

      def initialize(options = {})
        @options = options
      end

      def execute
        query = opt(:query) || opt(:q)

        # Empty/whitespace guard for the headless path (P2-H3): an empty
        # `-q`/`prompt ""` is truthy in Ruby, so it used to be dispatched
        # straight to the model — a wasted API turn and unpredictable
        # autonomous behaviour. Interactive mode already guards this
        # (`next if input.strip.empty?`); reject a blank one-shot query up
        # front with a clear stderr message + non-zero exit, BEFORE any setup,
        # model-config check, or runner is built. A nil query (bare `chat`)
        # is the interactive path and is left untouched.
        if query && query.strip.empty?
          warn "rubino: no prompt provided"
          exit(1)
        end

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

      def bang_shell
        @bang_shell ||= Chat::BangShell.new
      end

      # --- One-shot mode ---

      def run_oneshot(query)
        resolve_yolo!

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

        # Headless/scripted attachment: honour @image tokens in the prompt AND
        # explicit --image PATH flags, both routed to the native vision slot
        # (image_paths) — the same path the interactive REPL uses. Without this,
        # `-q` / `prompt` / `chat "..."` had no way to attach an image at all
        # (attachment was REPL-only); automation, jobs and tests can now drive it.
        text, image_paths = Chat::ImageInbox.resolve_oneshot(query, opt(:image))

        headless_ui = UI::Null.new
        runner = build_runner(session_id: session_resolver.resolve_session_id, ui: headless_ui)

        # Use run! (not run) so a model/credential failure PROPAGATES instead of
        # being swallowed into a nil and printed as an empty line with exit 0.
        # A brand-new user with no key would otherwise see ~80s of silent retries
        # then an empty prompt and a success exit (#93) — here we surface the
        # actionable error to stderr and exit non-zero so automation/the user can
        # actually tell it failed.
        announce_attachment_upload(image_paths)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = runner.run!(text, image_paths: image_paths)

        print_oneshot_answer(response.to_s)
        $stdout.flush

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
        if headless_ui.approval_blocked?
          headless_ui.blocked_messages.each { |m| warn m }
          exit(2)
        end
      # rubocop:disable Lint/ShadowedException -- Interrupt is listed explicitly (doc value), though SignalException covers it
      rescue Rubino::Interrupted, Interrupt, SystemExit, SignalException
        raise
      # rubocop:enable Lint/ShadowedException
      rescue Exception => e # rubocop:disable Lint/RescueException
        warn "rubino: #{e.message}"
        exit(1)
      ensure
        restore_logger(prev_log_io)
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

        cmd_executor = Rubino::Commands::Executor.new(ui: ui, runner: runner)
        cmd_loader   = Rubino::Commands::Loader.new

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
              runner = rewound
              cmd_executor = Rubino::Commands::Executor.new(ui: ui, runner: runner)
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
              result = cmd_executor.try_execute(input)
              case result
              when :exit    then break
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
                  runner = branch_runner(ui, runner, result[:title])
                  cmd_executor = Rubino::Commands::Executor.new(ui: ui, runner: runner)
                  next
                end
                if result[:resume_session_id]
                  # /sessions <id|title>: rebuild the runner on the chosen
                  # session in place and replay its history, then go back to the
                  # prompt — no process restart needed. Leaving a branch (e.g.
                  # back to the parent) drops the branch token from the status bar.
                  @branch_short_id = nil
                  runner = resume_runner(ui, result[:resume_session_id])
                  cmd_executor = Rubino::Commands::Executor.new(ui: ui, runner: runner)
                  next
                end
                if result[:compact_into]
                  # /compact: the compactor wrote head+summary+tail into a
                  # child session (the source is now status "compacted") —
                  # swap the runner into the child WITHOUT replaying history,
                  # so the next turn runs on the compacted context.
                  runner = build_runner(session_id: result[:compact_into], ui: ui)
                  cmd_executor = Rubino::Commands::Executor.new(ui: ui, runner: runner)
                  next
                end
                if result[:new_session]
                  # /new: end the current session and rebuild the runner on a
                  # fresh one in place — the counterpart to the bare-chat resume.
                  @branch_short_id = nil
                  runner.end_session!
                  runner = fresh_runner(ui)
                  cmd_executor = Rubino::Commands::Executor.new(ui: ui, runner: runner)
                  interacted = false
                  next
                end
                interacted = true
                run_turn(runner, result[:prompt], ui, input_queue)
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
          restore_signal_traps(prev_signal_traps)
          restore_logger(prev_log_io)
        end

        # Mark the session ended on a clean teardown (#100) so it stops showing
        # as "active" forever and cleanup/--continue can tell finished from live.
        runner.end_session!

        ui.blank_line
        ui.info("Session ended.")
        session_resolver.print_resume_hint(ui, runner.session) if interacted
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
        composer = UI::BottomComposer.new(
          input_queue: input_queue,
          prompt: build_prompt,
          rail: composer_rail,
          on_ctrl_o: ctrl_o_handler,
          on_mode_cycle: mode_cycle_handler(runner),
          completion_source: @completion_source,
          history: @input_history,
          echo: :prompt,
          pending_queued: pending_queued,
          status_line: build_status_line(runner),
          max_input_rows: Rubino.configuration.display_input_max_rows,
          paste_store: paste_store,
          on_double_esc: runner ? -> { rewind_pending = true } : nil
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

        # Gate idle Ctrl+C through the composer (BH-2): the composer runs under
        # raw(intr: true), so a single Ctrl+C still raises SIGINT — which would
        # otherwise hit the session-end / default handler and quit, silently
        # discarding a typed draft. Trap INT here so a draft is never nuked: the
        # trap body stays trap-safe (flip a flag only — Mutex#lock is forbidden
        # in a trap, Ruby #14222), and the poll loop below performs the actual
        # clear/hint/exit through the composer OUTSIDE trap context. Restored in
        # the ensure so the trap never leaks past the idle read.
        int_pending = false
        prev_int    = trap_idle_int { int_pending = true }

        line = nil
        loop do
          # Drained the idle Ctrl+C the trap recorded: clear the draft (non-empty)
          # or arm/confirm the two-tap exit (empty). Done here, not in the trap,
          # so the render mutex is safe.
          if int_pending
            int_pending = false
            break if composer.idle_interrupt(window: DOUBLE_TAP_SECONDS) == :exit
          end

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
      def run_turn(runner, prompt, ui, input_queue = nil)
        # A real turn has happened, so any prior probe is no longer the
        # "immediately-preceding interaction" — a later /branch must NOT fold it
        # into the seed. Clear it here, the single chokepoint for real turns.
        @last_probe = nil

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
              # "interrupted" wording (L10). Single ASCII write —
              # async-signal-safe enough for a trap.
              $stderr.write("\n(press Ctrl+C again to exit)\n")
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
        runner.run(prompt, **run_kwargs)
      rescue Interrupt
        # Reached on the second tap (raised from the trap) or a stray INT that
        # escaped the cooperative path. Cancel and re-raise so run_interactive's
        # loop breaks and the session ends cleanly.
        runner.cancel!
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
      # saturation. Saturation prefers the REAL
      # usage the provider reported for the session's last response (the
      # input_tokens the agent loop records in the assistant message metadata
      # — the whole assembled prompt incl. the system prompt) and falls back
      # to the SAME estimate the compaction logic runs on —
      # Context::TokenBudget#estimate_tokens (chars/4) over the stored
      # messages. The window comes from `model.context_length` /
      # `context.max_tokens` (TokenBudget's default otherwise), so the
      # percentage tracks the compaction thresholds. nil (no bar) when
      # disabled via display.statusbar or on any failure: a cosmetic line
      # must never break the prompt.
      def build_status_line(runner)
        return nil unless runner && Rubino.configuration.display_statusbar?

        session  = runner.session
        budget   = Context::TokenBudget.new(model_id: session[:model], config: Rubino.configuration)
        messages = ::Rubino::Session::Store.new.for_session(session[:id])
        UI::StatusBar.render(
          chips: { mode: Rubino::Modes.current, branch: @branch_short_id,
                   skill: Rubino::ActiveSkill.current },
          model: session[:model] || model_name,
          tokens: context_tokens(messages, budget),
          window: budget.available_tokens,
          pastel: pastel
        )
      rescue StandardError
        nil
      end

      # Estimated tokens in the session's context: the last recorded REAL
      # context size (input + output of the newest assistant response that
      # carries usage) when available, else TokenBudget's chars/4 estimate.
      def context_tokens(messages, budget)
        last = messages.reverse_each.find { |m| m.metadata&.dig(:input_tokens).to_i.positive? }
        return last.metadata[:input_tokens].to_i + last.token_count.to_i if last

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
          composer.print_above("#{build_prompt}#{line}")
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
          $stdout.puts("#{build_prompt}#{line}")
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
                                          paste_store: paste_store)
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

      # The composer's Enter-during-turn hook: cancel the runner so the just-
      # submitted line runs as the next turn. +quiet+ marks a slash-command
      # submit at an idle-LOOKING moment — nothing visibly streaming, only the
      # live cards animating (#111) — so the UI is told to swallow the
      # upcoming `⎿ interrupted` marker instead of stranding it above the
      # command's own output.
      def interrupt_handler(runner)
        lambda { |quiet = false|
          ui = Rubino.ui
          ui.suppress_interrupt_marker if quiet && ui.respond_to?(:suppress_interrupt_marker)
          runner.cancel!
        }
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
      rescue StandardError => e
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
          ui.status("added workspace #{collapse_home(real)}") if ui.respond_to?(:status)
          gate.ensure_trust(real)
        rescue ArgumentError => e
          ui.error("--add-dir #{dir}: #{e.message}") if ui.respond_to?(:error)
        end
      end

      def model_name
        opt(:model) || opt(:m) || Rubino.configuration.model_default
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
        if Rubino.configuration.model_provider.to_s == "fake" &&
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
        exit(1)
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
        return if Rubino.ensure_database_ready!

        warn "rubino isn't set up yet — run `rubino setup` first."
        exit(1)
      end
    end
  end
end
