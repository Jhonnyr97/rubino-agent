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
      def initialize(options = {})
        @options = options
      end

      def execute
        ensure_setup!
        ensure_model_configured!

        query = opt(:query) || opt(:q)
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

      def session_resolver
        @session_resolver ||= Chat::SessionResolver.new(@options)
      end

      def idle_cards
        @idle_cards ||= Chat::IdleCardHost.new
      end

      # --- One-shot mode ---

      def run_oneshot(query)
        apply_yolo! if opt(:yolo)

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

        runner = build_runner(session_id: session_resolver.resolve_session_id, ui: UI::Null.new)

        # Use run! (not run) so a model/credential failure PROPAGATES instead of
        # being swallowed into a nil and printed as an empty line with exit 0.
        # A brand-new user with no key would otherwise see ~80s of silent retries
        # then an empty prompt and a success exit (#93) — here we surface the
        # actionable error to stderr and exit non-zero so automation/the user can
        # actually tell it failed.
        announce_attachment_upload(image_paths)
        response = runner.run!(text, image_paths: image_paths)

        print_oneshot_answer(response.to_s)
        $stdout.flush
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
        apply_yolo! if opt(:yolo)

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
        @completion_source = build_completion_source(cmd_loader)
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
            input = next_input(input_queue)
            if input.nil? || exit_command?(input)
              break if confirm_quit?(ui)

              next
            end
            next if input.strip.empty?

            input = input.strip

            # Image-input commands manipulate the pending-attachment state local
            # to this REPL (not the agent), so they're handled here before the
            # slash dispatcher. `/paste` grabs a clipboard image; `/clear-images`
            # drops anything queued.
            next if image_inbox.handle_image_command(input, ui)

            # Pull any image references (@image, dropped/quoted path) out of the
            # line into image_paths (the native vision slot); the rest stays text.
            # An image-only line STAGES the attachment instead of submitting an
            # empty turn (#100): the in-prompt hint promises a "sent with your
            # next message (/clear-images to drop)" window, so honour it for
            # @image/dropped paths the same as /paste — the image goes out with
            # the next message that carries text.
            input = image_inbox.extract_images!(input, ui)
            next if input.empty?

            # A leading `? ` is the one-keystroke ephemeral probe (Option A of
            # the locked UX): the rest of the line is a side-question answered
            # from the session context, rendered in a dim aside, then DISCARDED
            # — nothing is written to the transcript. Handled BEFORE slash
            # dispatch so `? /foo` is still a probe about a literal `/foo`.
            if (question = probe_question(input))
              run_probe(runner, question, ui)
              next
            end

            if input.start_with?("/")
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
                  # back to the parent) drops the branch chip.
                  @branch_short_id = nil
                  runner = resume_runner(ui, result[:resume_session_id])
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
      def next_input(input_queue)
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

        # The bottom composer is the single idle input path on a real TTY: it
        # pins the prompt at the bottom, owns its own raw reader (so keys can't
        # smear the stream), redraws the mode chip LIVE on Shift+Tab, and hosts
        # the background-subagent card region (F1) when children are live. The
        # plain cooked readline is the fallback for non-TTY / piped / -q input.
        if UI::BottomComposer.active?
          read_idle_line(input_queue, draft)
        else
          cooked_input(build_prompt, draft)
        end
      end

      # Reads the user's next line at the IDLE prompt through the bottom composer
      # — the single input path. The composer pins the prompt at the bottom and
      # owns its own raw reader (full editing parity: arrows/Home/End/word-jump,
      # ↑↓ history, /command + @file completion menu with immediate-Esc dismiss,
      # cyan token highlight), redraws the mode chip LIVE on Shift+Tab, reveals
      # reasoning on Ctrl+O, and hosts the collapsed subagent card region (F1)
      # when background children are live — repaints land above the prompt and
      # update in place, serialized through the composer's render mutex.
      #
      # We seed the carried-over draft, then BLOCK until the user submits a line,
      # polling the same InputQueue the composer's reader pushes into (reusing the
      # turn loop's hand-off). A half-typed, un-submitted draft is preserved in
      # @pending_draft on teardown so it survives into the next prompt.
      def read_idle_line(input_queue, draft)
        composer = UI::BottomComposer.new(
          input_queue: input_queue,
          prompt: build_prompt,
          on_ctrl_o: ctrl_o_handler,
          on_mode_cycle: mode_cycle_handler,
          completion_source: @completion_source,
          history: @input_history,
          echo: :prompt,
          pending_queued: pending_queued
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
          # rest stay parked for the next #next_input / loop pass.
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

      # Window (seconds) for the Aider-style double-tap: a second Ctrl+C
      # within this of the first re-raises so the user can actually quit.
      DOUBLE_TAP_SECONDS = 2.0

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
        runner.run(prompt, image_paths: image_paths, input_queue: input_queue)
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
        stop_composer(composer, real_stdout)
        Signal.trap("INT", prev) if prev
      end

      # Commits the just-dequeued prompt as a normal "<prompt><line>" transcript
      # message and removes its "⏳ queued:" indicator. Each line the previous
      # turn parked (set in #next_input as @input_from_queue) is echoed in the
      # mode-aware prompt, so a queued/interrupt-sent message reads back exactly
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

        # Use the SAME mode-aware prompt as the between-turns Reline prompt
        # (default / plan / yolo ❯) so the bottom composer doesn't drop the mode.
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
                                          on_ctrl_o: ctrl_o_handler,
                                          on_mode_cycle: mode_cycle_handler,
                                          on_interrupt: interrupt_handler(runner),
                                          completion_source: @completion_source,
                                          history: @input_history,
                                          pending_queued: pending_queued)
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

      # The /probe wait indicator (#58): reuse the UI's thinking-row machinery
      # when present (UI::CLI). Guarded so Null/API adapters and piped stdout
      # stay silent.
      def probe_thinking_started(ui)
        return unless $stdout.tty? && ui.respond_to?(:thinking_started)

        ui.thinking_started
      end

      def probe_thinking_finished(ui)
        ui.thinking_finished if ui.respond_to?(:thinking_finished)
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

        child = Session::Repository.new.create(
          source: "cli",
          model: parent[:model],
          provider: parent[:provider],
          title: title,
          parent_session_id: parent[:id]
        )

        store.copy_into(child[:id], store.for_session(parent[:id]))
        included_probe = seed_probe_into!(store, child[:id])
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

      # Agent composer prompt — looks like an input field, not Bash/Zsh.
      # Mode is the only live context shown. Workspace, git, model, and
      # session are printed once at startup in startup_banner.
      #
      # After a `/branch`, the chip leads with `branch:<id>` so the user always
      # knows they're in a fork (and which one), composing with the mode chip.
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
      # Modes::ALL (default→plan→yolo→default), PERSIST it via Modes.set, commit a
      # transition footer above the pinned prompt, and RETURN the freshly-built
      # prompt chip so the composer redraws the chip LIVE. The composer holds no
      # mode logic — it just adopts the returned prompt.
      def mode_cycle_handler
        -> { cycle_mode }
      end

      # Shift+Tab: cycle the mode, show a SINGLE TRANSIENT confirmation banner,
      # and RETURN the freshly-built prompt chip so the composer adopts it and
      # redraws the chip LIVE (fixes the stale-chip D7). The persistent indicator
      # is the prompt CHIP; the banner is a one-shot toast rendered in the
      # composer's live region via #announce — redrawn in place, cleared on the
      # next keystroke, NEVER committed to scrollback. So cycling N times leaves
      # ZERO stacked banner lines (D3) and a mid-stream Shift+Tab can't wedge a
      # banner between answer chunks (D2). With no composer (cooked fallback) it
      # falls back to a plain dim line.
      #
      # Entering YOLO from the cycle is gated behind a second press (#152):
      # the press that lands on yolo only ARMS it and shows a confirm toast;
      # blind mashing past plan can no longer silently drop the approval gates
      # of the session AND its running background children. An explicit
      # `/mode yolo` stays direct.
      def cycle_mode
        previous = Rubino::Modes.current
        idx      = Rubino::Modes::ALL.index(previous) || 0
        nxt      = Rubino::Modes::ALL[(idx + 1) % Rubino::Modes::ALL.length]
        return announce_yolo_confirm if nxt == Rubino::Modes::YOLO && !yolo_cycle_confirmed?

        @yolo_armed_at = nil
        Rubino::Modes.set(nxt)
        # Same `<old> → <new>` arrow grammar as the /mode footer (#78), plus
        # the description and the cycle hint only this transient toast carries.
        show_mode_footer("┄ mode #{previous} → #{nxt} — #{Rubino::Modes.description(nxt)}, shift+tab to cycle ┄")
        build_prompt
      end

      # The confirm press must come after a deliberate beat (a blind mash
      # re-arms instead of confirming — the exact failure mode of #152 was
      # 2-5 quick presses while watching the stream) and before the arm goes
      # stale (the toast is long gone; a lone later press must re-confirm).
      YOLO_CONFIRM_MIN_SECONDS    = 0.3
      YOLO_CONFIRM_WINDOW_SECONDS = 5.0

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
      # confirm. Returns the unchanged prompt chip (the mode did not change).
      def announce_yolo_confirm
        live = Tools::BackgroundTasks.instance.running.size
        children = live.positive? ? " — #{live} running subagent(s) will run gated actions unprompted" : ""
        show_mode_footer("┄ yolo skips ALL approvals#{children} — press shift+tab again to confirm ┄")
        build_prompt
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

      def build_prompt
        chip = mode_label
        chip = "#{pastel.cyan("branch:#{@branch_short_id}")} #{chip}" if @branch_short_id
        chip = "#{chip}#{skill_label}"
        "#{chip} #{PROMPT_CARET} "
      end

      # The active-skill segment of the prompt chip: a dim ` (skill: <name>)`
      # appended after the mode chip, e.g. `default (skill: ruby-expert) ❯`. Empty
      # when no skill is pinned (Rubino::ActiveSkill), so the chip returns to a
      # plain `default ❯`. Styled dim to match the mode chip's quiet register.
      # The chip refreshes live: each idle prompt rebuilds the composer with a
      # freshly-built prompt, so activating/clearing a skill updates it next turn.
      def skill_label
        skill = Rubino::ActiveSkill.current
        return "" unless skill

        pastel.dim(" (skill: #{skill})")
      end

      def mode_label
        p = pastel
        mode = Rubino::Modes.current
        case mode
        when Rubino::Modes::PLAN then p.cyan("plan")
        when Rubino::Modes::YOLO then p.yellow.bold("yolo")
        # The prompt chip must match the canonical mode name used everywhere
        # else — Modes::DEFAULT, `/mode default | plan | yolo`, and the
        # `mode default → plan` transition banner — instead of inventing a
        # second label "general" for the same mode (F9).
        else p.dim("default")
        end
      end

      PROMPT_CARET = "❯"

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

      # --- Interactive line input with autocomplete ---

      # Configures line completion for slash commands.
      #
      # Note: must use `::Rubino::Commands` (or the equivalent absolute
      # path) — inside `Rubino::CLI::ChatCommand` a bare `Commands`
      # resolves to `Rubino::CLI::Commands` (the Thor class), which has
      # no `BuiltIns` constant and raises NameError at first interactive
      # boot.
      # Builds the shared UI::CompletionSource the bottom composer's /command +
      # @file completion menu consults. The command list is built the same way
      # the old Reline completion was fed (built-ins + loaded custom commands);
      # `@` is a workspace file picker (lazy — discovered + cached on the first
      # `@`, same root rule as Tools::Base#workspace_root).
      #
      # Note: must use `::Rubino::Commands` (or the equivalent absolute path) —
      # inside `Rubino::CLI::ChatCommand` a bare `Commands` resolves to
      # `Rubino::CLI::Commands` (the Thor class), which has no `BuiltIns` constant
      # and raises NameError at first interactive boot.
      def build_completion_source(cmd_loader)
        custom = begin
          cmd_loader.names
        rescue StandardError
          []
        end
        names  = (::Rubino::Commands::BuiltIns::NAMES + custom).uniq
        files  = -> { Rubino::Workspace.primary_root }
        # ARGUMENT sources: the dropdown completes the argument of these commands
        # the same way it completes `/command` and `@file`.
        #   * /skills <partial> — a skill name (lazily re-read each open so a
        #     freshly-authored skill appears), TRUST-aligned with the prompt
        #     assembler (#63) so the picker never offers a skill that won't pin.
        #   * /agents (alias /tasks) — the live subagent ids, then the
        #     steer/probe/--stop subcommand grammar, so the comm surface is
        #     discoverable from the composer (#39).
        #   * /reply — the ids of children blocked waiting on the human.
        #   * /mcp — the configured server names (+ reload), then on/off for a
        #     named server (#182), same grammar shape as /agents.
        #   * /mode, /reasoning, /think — the closed enums (#185), via the
        #     positional shape so no `✗ none` clear entry is injected (there
        #     is no "clear" for a mode — see CompletionSource#initialize).
        #   * /add-dir — filesystem DIRECTORY candidates from the typed
        #     partial (#185), via the partial-aware two-arg shape.
        #   * /sessions, /memory — verbs + recent ids (#183/#184), the same
        #     per-position grammar /agents ships.
        #   * /jobs — recent job ids (#187); /config — the get/set/show/path
        #     verbs + the known config keys flattened from the defaults tree.
        #   * /skills — the `✗ none` clear entry + the enable/disable verbs +
        #     the skill names (#188); after a toggle verb, the names again.
        arg_sources = {
          "skills" => ->(args) { skills_arg_candidates(args) },
          "agents" => ->(args) { agents_arg_candidates(args) },
          "tasks" => ->(args) { agents_arg_candidates(args) },
          "reply" => ->(args) { args.empty? ? blocked_subagent_ids : [] },
          "mcp" => ->(args) { mcp_arg_candidates(args) },
          "mode" => ->(args) { args.empty? ? Rubino::Modes::ALL.map(&:to_s) : [] },
          "reasoning" => ->(args) { args.empty? ? Rubino::Config::ReasoningPrefs::RENDER_MODES.map(&:to_s) : [] },
          "think" => ->(args) { args.empty? ? Rubino::Config::ReasoningPrefs::EFFORTS.map(&:to_s) : [] },
          "add-dir" => lambda { |args, partial|
            args.empty? ? Rubino::UI::CompletionSource.directory_candidates(partial) : []
          },
          "sessions" => ->(args) { sessions_arg_candidates(args) },
          "memory" => ->(args) { memory_arg_candidates(args) },
          "jobs" => ->(args) { args.empty? ? recent_job_ids : [] },
          "config" => ->(args) { config_arg_candidates(args) }
        }
        Rubino::UI::CompletionSource.new(commands: names, files: files,
                                         arg_sources: arg_sources,
                                         descriptions: completion_descriptions(cmd_loader))
      end

      # The /agents subcommand grammar offered by the dropdown (#39): first an
      # id, then what you can do to it.
      AGENTS_SUBCOMMANDS = ["steer", "probe", "--stop"].freeze

      # Argument candidates per /agents position: ids → subcommands → nothing.
      def agents_arg_candidates(args)
        case args.length
        when 0 then Tools::BackgroundTasks.instance.list.map(&:id)
        when 1 then AGENTS_SUBCOMMANDS
        else []
        end
      end

      # Children parked on an ask_parent waiting for the human — the ids /reply
      # answers.
      def blocked_subagent_ids
        Tools::BackgroundTasks.instance.awaiting_human.map(&:id)
      end

      # The /mcp subcommand grammar (#182): configured server names + reload
      # first, then the on/off verbs for a named server.
      MCP_SUBCOMMANDS = %w[on off].freeze

      def mcp_arg_candidates(args)
        case args.length
        when 0 then mcp_server_names + ["reload"]
        when 1 then args.first == "reload" ? [] : MCP_SUBCOMMANDS
        else []
        end
      end

      def mcp_server_names
        (Rubino.configuration.dig("mcp", "servers") || {}).keys.map(&:to_s)
      rescue StandardError
        []
      end

      # The /sessions subcommand grammar (#183): verbs + recent session ids
      # first (bare id resumes, verb then id shows/deletes), then ids after a
      # verb. Mirrors the /agents grammar so the picker teaches the surface.
      SESSIONS_SUBCOMMANDS = ["show", "delete", "--all"].freeze

      def sessions_arg_candidates(args)
        case args.length
        when 0 then SESSIONS_SUBCOMMANDS + recent_session_ids
        when 1 then %w[show delete].include?(args.first) ? recent_session_ids : []
        else []
        end
      end

      # Recent session ids for the /sessions dropdown — same source the
      # in-chat list reads (Session::Repository#list). Best-effort: a DB
      # hiccup degrades to no id candidates, never a broken prompt.
      def recent_session_ids
        Rubino::Session::Repository.new.list(limit: 10).map { |s| s[:id].to_s }
      rescue StandardError
        []
      end

      # The /memory subcommand grammar (#184): verbs first, then recent fact
      # ids after show/forget (short ids — the store resolves prefixes) or the
      # registered backend names after backend.
      MEMORY_SUBCOMMANDS = ["search", "show", "forget", "backend", "--all"].freeze

      def memory_arg_candidates(args)
        case args.length
        when 0 then MEMORY_SUBCOMMANDS
        when 1
          case args.first
          when "show", "forget" then recent_memory_ids
          when "backend" then Rubino::Memory::Backends.names
          else []
          end
        else []
        end
      end

      # Recent fact ids (short form) for the /memory show/forget dropdown,
      # read from the ACTIVE backend — the same store /memory manages.
      def recent_memory_ids
        Rubino::Memory::Backends.build.list(limit: 10).map { |m| m[:id].to_s[0..7] }
      rescue StandardError
        []
      end

      # The /skills grammar (#188): position one mixes the `✗ none` clear entry
      # (CompletionSource keeps its special matching), the enable/disable verbs
      # and the activate-by-name skill list; after a toggle verb, the names
      # complete again. Activate-by-name and `✗ none` behave exactly as before.
      SKILLS_SUBCOMMANDS = %w[enable disable].freeze

      def skills_arg_candidates(args)
        case args.length
        when 0 then [Rubino::UI::CompletionSource::NONE_ENTRY] + SKILLS_SUBCOMMANDS + skill_names
        when 1 then SKILLS_SUBCOMMANDS.include?(args.first) ? skill_names : []
        else []
        end
      end

      # TRUST-aligned skill names (#63), lazily re-read each open so a
      # freshly-authored skill appears. Best-effort, like the other sources.
      def skill_names
        Rubino::Skills::Registry.trusted.names
      rescue StandardError
        []
      end

      # Recent job ids (the short form the /jobs table renders — the queue
      # resolves prefixes) for the /jobs dropdown (#187).
      def recent_job_ids
        Rubino::Jobs::Queue.new.list(limit: 10).map { |j| j[:id].to_s[0..7] }
      rescue StandardError
        []
      end

      # The /config grammar (#187): verbs + the known config keys first (a
      # bare key gets, key+value sets), keys again after get/set.
      CONFIG_SUBCOMMANDS = %w[get set show path].freeze

      def config_arg_candidates(args)
        case args.length
        when 0 then CONFIG_SUBCOMMANDS + config_key_candidates
        when 1 then %w[get set].include?(args.first) ? config_key_candidates : []
        else []
        end
      end

      # The KNOWN config vocabulary: every leaf dot-path in the defaults tree
      # (Config::Defaults.to_hash) — the same keys `config get` resolves
      # against. Discovery, not validation: a key only present in the user's
      # config.yml still works typed by hand.
      def config_key_candidates
        flatten_config_keys(Rubino::Config::Defaults.to_hash)
      rescue StandardError
        []
      end

      def flatten_config_keys(tree, prefix = nil)
        tree.flat_map do |key, value|
          path = [prefix, key.to_s].compact.join(".")
          value.is_a?(Hash) && !value.empty? ? flatten_config_keys(value, path) : [path]
        end
      end

      # One-line descriptions for the dropdown (#39): the SAME strings /help
      # shows (BuiltIns + custom command frontmatter), plus usage hints for the
      # /agents subcommand grammar. Best-effort — a loader hiccup degrades to
      # built-ins only, never breaks the prompt.
      def completion_descriptions(cmd_loader)
        descriptions = ::Rubino::Commands::BuiltIns::DESCRIPTIONS.dup
        begin
          cmd_loader.all.each do |cmd|
            desc = cmd.description.to_s.strip
            descriptions["/#{cmd.name}"] = desc unless desc.empty?
          end
        rescue StandardError
          nil
        end
        descriptions.merge(
          "steer" => "park a note the subagent folds in at its next turn",
          "probe" => "ask the subagent an ephemeral question (not saved)",
          "--stop" => "cancel the running subagent",
          # /mcp verbs (#182). "off" is ALSO /think's zero effort (#185) —
          # descriptions are keyed by candidate string, so the one line
          # covers both surfaces.
          "reload" => "re-read config.yml and reconnect every MCP server",
          "on" => "(re)start the MCP server and register its tools",
          "off" => "mcp: stop the server and its tools · think: no thinking budget",
          # /sessions + /memory verbs (#183/#184). "show"/"--all" are shared
          # by both grammars — and "show" by /config too (#187) — so each
          # one-liner covers all its surfaces.
          "show" => "show full details (sessions/memory: by id · config: the whole tree)",
          "delete" => "delete a session and its messages (asks to confirm)",
          "search" => "search facts by substring",
          "forget" => "delete a fact by id",
          "backend" => "show the active memory backend",
          "--all" => "list everything (sessions: no row cap · memory: incl. retired)",
          # /config verbs (#187) + /skills toggle verbs (#188).
          "get" => "read one config value (dot-notation, merged over defaults)",
          "set" => "write one config value (persisted to config.yml)",
          "path" => "print the config file path",
          "enable" => "put a skill back in the index (every session)",
          "disable" => "drop a skill from the index (every session, persisted)",
          # The closed enums (#185) reuse the same wording the commands print.
          "default" => Rubino::Modes.description(:default),
          "plan" => Rubino::Modes.description(:plan),
          "yolo" => Rubino::Modes.description(:yolo),
          "hidden" => "show no reasoning (Ctrl-O reveals the last)",
          "collapsed" => "a dim one-line cue; Ctrl-O expands",
          "full" => "the whole reasoning as a dim aside",
          "low" => "small thinking-token budget",
          "medium" => "medium thinking-token budget (default)",
          "high" => "large thinking-token budget"
        )
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
      def build_runner(session_id:, ui:)
        Agent::Runner.new(
          session_id: session_id,
          model_override: model_name,
          provider_override: opt(:provider),
          max_turns: max_turns_override,
          ignore_rules: opt(:ignore_rules) || false,
          ui: ui
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

      # `--yolo` is the CLI flag form of `/mode yolo`. We route both through
      # Rubino::Modes so the chip in build_prompt, the API event, and the
      # ApprovalPolicy short-circuit all see a single source of truth.
      def apply_yolo!
        Rubino::Modes.set(:yolo)
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
        Rubino::Tools::Registry.register_defaults! if Rubino::Tools::Registry.all.empty?

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

      def exit_command?(input)
        %w[exit quit bye /exit /quit].include?(input.strip.downcase)
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
