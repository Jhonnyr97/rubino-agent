# frozen_string_literal: true

require "time"
require "pastel"
require "io/console"

module Rubino
  module CLI
    # Interactive and non-interactive chat session command.
    # Supports predecessor compatible flags:
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
        $stderr.puts e.message
        exit(1)
      end

      private

      # --- One-shot mode ---

      def run_oneshot(query)
        apply_yolo! if opt(:yolo)

        # Surface the resolved model (and any unknown-id warning) before the
        # answer (#142). In one-shot mode there is no chat header, so without
        # this a typo'd `-m` silently runs the wrong/forced-through model with
        # zero feedback. Echo only when the user passed an explicit override so
        # we don't add noise to the default-model happy path.
        announce_resolved_model

        # Headless/scripted attachment: honour @image tokens in the prompt AND
        # explicit --image PATH flags, both routed to the native vision slot
        # (image_paths) — the same path the interactive REPL uses. Without this,
        # `-q` / `prompt` / `chat "..."` had no way to attach an image at all
        # (attachment was REPL-only); automation, jobs and tests can now drive it.
        text, image_paths = resolve_oneshot_images(query)

        runner = Agent::Runner.new(
          session_id:        resolve_session_id,
          model_override:    model_name,
          provider_override: opt(:provider),
          max_turns:         max_turns_override,
          ignore_rules:      opt(:ignore_rules) || false,
          ui:                UI::Null.new
        )

        # Use run! (not run) so a model/credential failure PROPAGATES instead of
        # being swallowed into a nil and printed as an empty line with exit 0.
        # A brand-new user with no key would otherwise see ~80s of silent retries
        # then an empty prompt and a success exit (#93) — here we surface the
        # actionable error to stderr and exit non-zero so automation/the user can
        # actually tell it failed.
        response = runner.run!(text, image_paths: image_paths)

        $stdout.puts response.to_s
        $stdout.flush
      rescue Rubino::Interrupted, Interrupt, SystemExit, SignalException
        raise
      rescue Exception => e # rubocop:disable Lint/RescueException
        $stderr.puts "rubino: #{e.message}"
        exit(1)
      end

      # Builds the [text, image_paths] pair for a one-shot turn. Pulls @image /
      # dropped-path tokens out of the prompt (so they hit the vision slot, not
      # the literal text) and prepends any paths given via --image. Flag paths
      # are expanded the same way as in-line tokens; a flag path that isn't a
      # readable image is reported and skipped rather than silently dropped.
      def resolve_oneshot_images(query)
        flag_paths = Array(opt(:image)).map { |p| Interaction::ImageInput.expand(p) }
        flag_paths.each do |p|
          next if LLM::ContentBuilder.image_file?(p) && File.file?(p)

          $stderr.puts "rubino: ignoring --image #{p} (not a readable image file)"
        end
        valid_flags = flag_paths.select { |p| LLM::ContentBuilder.image_file?(p) && File.file?(p) }

        result = Interaction::ImageInput.parse(query, existing: valid_flags)
        [result.text, result.image_paths]
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
        ui.blank_line

        runner = Agent::Runner.new(
          session_id:        resolve_session_id(auto_resume: true),
          model_override:    model_name,
          provider_override: opt(:provider),
          max_turns:         max_turns_override,
          ignore_rules:      opt(:ignore_rules) || false,
          ui:                ui
        )

        # The runner already announced the session ("New/Resuming session: <id>");
        # re-printing the full uuid here was the third copy of the same id on boot
        # (#82). The short id is enough; the full one lives in /status.

        # Best-effort: a closed terminal / kill marks the session ended too (#100).
        prev_signal_traps = install_session_end_traps(runner)

        cmd_executor = Rubino::Commands::Executor.new(ui: ui, runner: runner)
        cmd_loader   = Rubino::Commands::Loader.new
        line_input   = Rubino::UI::LineInput.new

        setup_readline_completions(cmd_loader, line_input)

        if resuming_session?
          # On a bare-chat auto-resume (#99) tell the user, clearly and once,
          # that we picked up their last session and how to start fresh —
          # otherwise the continuation is silent and looks like a fresh boot.
          print_auto_resume_line(ui, runner.session) if @auto_resumed_session
          print_session_history(ui, runner.session[:id])
        else
          # First-run welcome panel: the same assembler /status uses, trimmed.
          Rubino::Commands::Executor.welcome(runner: runner, ui: ui)
        end

        # Steering: lines the user types *during* a turn are captured by the
        # background reader (see #run_turn) and parked here. At the next turn
        # boundary we drain them and they become the next prompt, so a message
        # typed while the agent was working is answered as the next turn with
        # no copy/paste — instead of blocking on a fresh readline.
        input_queue = Rubino::Interaction::InputQueue.new

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
            input = next_input(input_queue, line_input)
            break if input.nil? || exit_command?(input)
            next if input.strip.empty?

            input = input.strip

            # Image-input commands manipulate the pending-attachment state local
            # to this REPL (not the agent), so they're handled here before the
            # slash dispatcher. `/paste` grabs a clipboard image; `/clear-images`
            # drops anything queued.
            next if handle_image_command(input, ui)

            # Pull any image references (@image, dropped/quoted path) out of the
            # line into image_paths (the native vision slot); the rest stays text.
            input = extract_images!(input, ui)
            next if input.empty? && pending_image_paths.empty?
            # An image with no accompanying words still needs a user turn; give
            # the model a default question so it has something to answer.
            input = "What do you see in this image?" if input.empty?

            if input.start_with?("/")
              result = cmd_executor.try_execute(input)
              case result
              when :exit    then break
              when :handled then next
              when Hash
                if result[:resume_session_id]
                  # /sessions <id|title>: rebuild the runner on the chosen
                  # session in place and replay its history, then go back to the
                  # prompt — no process restart needed.
                  runner = resume_runner(ui, result[:resume_session_id])
                  cmd_executor = Rubino::Commands::Executor.new(ui: ui, runner: runner)
                  next
                end
                if result[:new_session]
                  # /new: end the current session and rebuild the runner on a
                  # fresh one in place — the counterpart to the bare-chat resume.
                  runner.end_session!
                  runner = fresh_runner(ui)
                  cmd_executor = Rubino::Commands::Executor.new(ui: ui, runner: runner)
                  interacted = false
                  next
                end
                interacted = true; run_turn(runner, result[:prompt], ui, input_queue)
              else               interacted = true; run_turn(runner, input, ui, input_queue)
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
        print_resume_hint(ui, runner.session) if interacted
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

      # Routes the structured logger to a file for the interactive session so
      # JSON log lines never reach the terminal $stdout the TUI renders into
      # (#125). Returns the previous sink IO to restore on exit; nil (no-op,
      # logger untouched) if the file can't be opened — a logging-destination
      # detail must never break the chat boot.
      def redirect_logger_to_file
        dir  = File.expand_path(Rubino.configuration.dig("paths", "logs") || "~/.rubino/logs")
        FileUtils.mkdir_p(dir)
        file = File.open(File.join(dir, "rubino.log"), "a")
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

      # Next prompt for the REPL. If the user typed while the previous turn
      # ran, those lines were parked in the InputQueue; consume them as the
      # next prompt INSTEAD of blocking on a fresh readline. Multiple lines are
      # coalesced (newline-joined) into one next-turn user message — the MVP
      # keeps steering at the turn boundary, not mid-tool. When nothing was
      # queued, fall back to the normal readline prompt.
      def next_input(input_queue, line_input)
        queued = input_queue.drain
        return queued.join("\n") unless queued.empty?

        # Carry over any draft the user typed into the bottom composer during the
        # previous turn but never submitted (no Enter): the composer is torn down
        # at turn end, so without this the in-progress text would vanish. Consume
        # it once — the next cooked prompt starts empty again.
        draft = @pending_draft
        @pending_draft = nil

        # F1: a `task` is background-by-default, so the model ends its turn the
        # instant it gets the handle and the child runs ~15-20s ENTIRELY BETWEEN
        # turns — at THIS idle prompt. The turn-scoped composer is already torn
        # down here, so the collapsed live cards (driven by the child EventBus
        # taps → #set_subagent_cards, which key off BottomComposer.current) had
        # nowhere to render and were never seen in a real session. Host them at
        # the idle prompt too: while any background child is live AND both ends
        # are a TTY, read the next line through a BottomComposer that owns the
        # card region, so the same child repaints land above the prompt and
        # update in place. The moment the last child finishes the region clears
        # and we fall back to the normal Reline prompt (carrying any draft).
        if background_children_live? && UI::BottomComposer.active?
          line = read_idle_line_with_cards(input_queue, draft)
          return line unless line.nil?

          # The card composer handed control back because the children finished
          # (not because the user submitted): carry the draft into the normal
          # prompt below so nothing the user typed is lost.
          draft = @pending_draft
          @pending_draft = nil
        end

        readline_input(line_input, build_prompt, initial: draft)
      end

      # True when at least one background subagent (the `task` tool's default)
      # is still live — running or parked on a human approval. Drives whether the
      # idle prompt hosts the collapsed live cards (F1).
      def background_children_live?
        Tools::BackgroundTasks.instance.running.any?
      rescue StandardError
        false
      end

      # How often (seconds) the idle card region repaints on its own so the
      # cards' elapsed-time field advances even when no child event fires, and so
      # we promptly notice the last child finishing. Child tool start/finish
      # already poke an immediate repaint via #set_subagent_cards; this tick only
      # covers the quiet gaps.
      IDLE_CARD_TICK = 1.0

      # Reads the user's next line at the IDLE prompt while background subagents
      # run, hosting the collapsed live cards above it (F1). Reuses the SAME
      # machinery a parent turn uses: a BottomComposer (so BottomComposer.current
      # is set and the child EventBus taps' #set_subagent_cards repaints land in
      # its card region), the registry snapshot, and the render mutex + explicit
      # row-count clear #129 added.
      #
      # Returns the submitted line (already pushed by the composer's reader and
      # drained here), or nil when the LAST child finished before the user
      # submitted — in which case the caller falls back to the normal Reline
      # prompt, and any half-typed draft is preserved in @pending_draft.
      #
      # Concurrency: the card region is repainted from child worker threads while
      # the user may be typing. Every repaint and every keystroke serialize on the
      # composer's render mutex (the exact path the #129 verifier confirmed safe
      # for 3 cards + typing + resize), so a tick or a child event can never
      # corrupt the input buffer or desync the frame.
      def read_idle_line_with_cards(input_queue, draft)
        composer = UI::BottomComposer.new(input_queue: input_queue, prompt: build_prompt)
        composer.start
        # Seed the carried-over draft char-by-char so backspace stays
        # codepoint-granular (handle_key chops one codepoint at a time).
        draft.to_s.each_char { |c| composer.handle_key(c) } if draft && !draft.to_s.empty?
        paint_idle_cards
        ticker = start_idle_card_ticker(composer)

        # Block until the user submits a line OR the last child finishes. The
        # composer's own raw reader pushes the submitted line into the queue; we
        # poll the queue (not a bespoke condvar) so this reuses the same hand-off
        # the turn loop already drains.
        line = nil
        loop do
          queued = input_queue.drain
          unless queued.empty?
            line = queued.join("\n")
            break
          end
          break unless background_children_live?

          sleep(0.05)
        end
        line
      ensure
        ticker&.kill
        ticker&.join
        # Preserve a half-typed, un-submitted draft so the fallback prompt
        # pre-fills it (same contract as the turn-scoped composer teardown).
        if composer
          pending = composer.buffer.to_s
          @pending_draft = pending unless pending.strip.empty?
        end
        composer&.stop
      end

      # Repaints the idle card region from the registry's current snapshot. Mirrors
      # UI::CLI#set_subagent_cards (which the child taps call), but is callable
      # from the REPL's own ticker without a parent UI handle — both ultimately
      # drive BottomComposer#set_cards under the render mutex.
      def paint_idle_cards
        composer = UI::BottomComposer.current
        return unless composer

        entries = Tools::BackgroundTasks.instance.running
        composer.set_cards(idle_subagent_cards.card_lines(entries))
      rescue StandardError
        nil # a card repaint is cosmetic — never break the idle prompt.
      end

      def idle_subagent_cards
        @idle_subagent_cards ||= UI::SubagentCards.new
      end

      # A low-frequency ticker that repaints the idle card region so the elapsed
      # time advances and a finished last-child is noticed even in a quiet gap
      # between child events. Repaints go through the composer's render mutex, so
      # they never race the keystroke handler. Exits as soon as no child is live
      # (it clears the region one last time) or when killed on teardown.
      def start_idle_card_ticker(composer)
        Thread.new do
          loop do
            sleep(IDLE_CARD_TICK)
            break unless composer.equal?(UI::BottomComposer.current)

            paint_idle_cards
            break unless background_children_live?
          end
        rescue StandardError
          nil
        end
      end

      # --- Image input (attach an image from the terminal) ---
      #
      # Attachments live in @pending_image_paths between the prompt read and the
      # turn; run_turn consumes + clears them so each image is sent once into the
      # native vision slot (image_paths → Lifecycle#execute → adapter `with:`).

      def pending_image_paths
        @pending_image_paths ||= []
      end

      # Parses the line for image references (@image, dropped/quoted/escaped
      # path), moves any into @pending_image_paths and returns the cleaned text.
      # Non-image references are left in the text (current behaviour). Shows an
      # in-prompt indicator for whatever is now attached.
      def extract_images!(input, ui)
        result = Interaction::ImageInput.parse(input, existing: pending_image_paths)
        newly  = result.image_paths - pending_image_paths
        @pending_image_paths = result.image_paths
        show_image_indicator(ui, newly) unless newly.empty?
        result.text
      end

      # Handles the REPL-local image commands. Returns true when it consumed the
      # input (so the main loop should `next`), false otherwise.
      #
      #   /paste         — grab an image from the clipboard into image_paths
      #   /clear-images  — drop all pending attachments
      def handle_image_command(input, ui)
        case input.strip.downcase
        when "/clear-images", "/clear-image"
          if pending_image_paths.empty?
            ui.info("No attached images to clear.")
          else
            ui.info("Cleared #{pending_image_paths.size} attached image(s).")
            @pending_image_paths = []
          end
          true
        when "/paste"
          paste_clipboard_image(ui)
          true
        else
          false
        end
      end

      def paste_clipboard_image(ui)
        path = Interaction::ClipboardImage.save_to_tempfile
        if path
          pending_image_paths << path unless pending_image_paths.include?(path)
          show_image_indicator(ui, [path])
        else
          ui.warning("Clipboard paste failed: #{Interaction::ClipboardImage.unavailable_reason}")
        end
      end

      # In-prompt indicator of attached image(s), Claude-Code style.
      def show_image_indicator(ui, newly)
        newly.each { |p| ui.status("[image: #{File.basename(p)}]") }
        total = pending_image_paths.size
        ui.status("#{total} image#{'s' if total != 1} attached — sent with your next message (/clear-images to drop).")
      end

      # On exit, hand the user back the exact command to return to this chat.
      # Claude Code prints no equivalent hint; without this, the session id
      # is buried in ~/.claude state and the user has to guess at --resume
      # or scroll back through history. Prefer the human-friendly title when
      # one is set; fall back to the id otherwise.
      # One-liner shown when a bare `chat` auto-resumed the last session (#99),
      # so the continuation is never silent and the user knows how to opt out.
      def print_auto_resume_line(ui, session)
        return unless session

        title = session[:title].to_s.strip
        label = title.empty? ? session[:id][0..7] : %("#{title}")
        ui.status("▸ resuming #{label} (#{session[:id][0..7]}) — /new for a fresh session")
      end

      def print_resume_hint(ui, session)
        return unless session
        id    = session[:id]
        title = session[:title]
        handle = title && !title.to_s.strip.empty? ? %("#{title}") : id
        return unless handle

        ui.info("Resume with: rubino chat --resume #{handle}")
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
        # Consume the turn's queued image attachments (the native vision slot)
        # and reset so they're attached exactly once, not re-sent next turn.
        image_paths = pending_image_paths
        @pending_image_paths = []

        last_int_at = nil
        in_trap     = false

        prev = Signal.trap("INT") do
          # Guard against trap re-entrancy: a burst of signals must not stack.
          unless in_trap
            in_trap = true
            begin
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              if last_int_at && (now - last_int_at) <= DOUBLE_TAP_SECONDS
                # Second tap in the window: raise to the main thread so the
                # REPL unwinds and exits — a real Ctrl+C now quits.
                raise Interrupt
              else
                last_int_at = now
                runner.cancel!
                # The runner emits the "⚠ interrupted by user" line once it
                # unwinds the cancelled turn; here we only add the actionable
                # double-tap hint so the two messages don't restate the same
                # "interrupted" wording (L10). Single ASCII write —
                # async-signal-safe enough for a trap.
                $stderr.write("\n(press Ctrl+C again to exit)\n")
              end
            ensure
              in_trap = false
            end
          end
        end

        composer, real_stdout = start_composer(input_queue)

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
        stop_composer(composer, real_stdout)
        Signal.trap("INT", prev) if prev
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
      def start_composer(input_queue)
        return [nil, nil] unless input_queue && UI::BottomComposer.active?

        # Use the SAME mode-aware prompt as the between-turns Reline prompt
        # (default / plan / yolo ❯) so the bottom composer doesn't drop the mode.
        composer = UI::BottomComposer.new(input_queue: input_queue, prompt: build_prompt)
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

      # --- Session history replay (resume / continue) ---
      #
      # PromptAssembler feeds the past turns to the model on every request, but
      # the inline REPL never printed them. On --resume the terminal looked
      # empty even though the model had full context. Replay user, assistant
      # and tool messages through the existing UI methods so the scrolled-back
      # transcript matches what the user originally saw.
      def print_session_history(ui, session_id)
        return unless session_id

        messages = ::Rubino::Session::Store.new.for_session(session_id)
        return if messages.empty?

        ui.status("Loaded #{messages.size} prior message#{'s' if messages.size != 1}")
        ui.separator

        messages.each do |msg|
          at = parse_msg_timestamp(msg.created_at)
          case msg.role.to_s
          when "user"
            ui.replay_user_input(msg.content, at: at)
          when "assistant"
            next if msg.content.nil? || msg.content.to_s.empty?
            # Render the prior assistant turn as markdown, same as a live reply —
            # not the old box (which the M2 redesign repurposed into a "● running"
            # tool-style row, so resume showed assistant turns as fake tool runs
            # with raw markdown).
            ui.assistant_text(msg.content)
          when "tool"
            name      = msg.tool_name || "tool"
            arguments = msg.metadata.is_a?(Hash) ? msg.metadata[:arguments] : nil
            ui.tool_started(name, arguments: arguments, at: at)
            ui.tool_finished(
              name,
              result: ::Rubino::Tools::Result.success(
                name:    name,
                call_id: msg.tool_call_id,
                output:  msg.content.to_s
              )
            )
          end
        end

        ui.separator
      end

      # Agent composer prompt — looks like an input field, not Bash/Zsh.
      # Mode is the only live context shown. Workspace, git, model, and
      # session are printed once at startup in startup_banner.
      def build_prompt
        "#{mode_label} #{PROMPT_CARET} "
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
        else                             p.dim("default")
        end
      end

      PROMPT_CARET = "❯".freeze

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

      # Best-effort parse of the timestamp the DB stored on a Message.
      # Sequel hands these back as either a Time or an ISO8601 String
      # depending on adapter and column type; the replay code wants a Time
      # to feed to `ui.box_open(at:)`. Anything unparseable falls back to nil
      # and the header shows "now" — better than crashing on replay.
      def parse_msg_timestamp(value)
        return value if value.is_a?(Time)
        return nil if value.nil? || value.to_s.empty?

        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      # --- Interactive line input with autocomplete ---

      # Configures line completion for slash commands.
      #
      # Note: must use `::Rubino::Commands` (or the equivalent absolute
      # path) — inside `Rubino::CLI::ChatCommand` a bare `Commands`
      # resolves to `Rubino::CLI::Commands` (the Thor class), which has
      # no `BuiltIns` constant and raises NameError at first interactive
      # boot.
      def setup_readline_completions(cmd_loader, line_input = Rubino::UI::LineInput.new)
        custom = cmd_loader.names rescue []
        names  = ::Rubino::Commands::BuiltIns::NAMES + custom
        # `@` is a workspace file picker (subagent mentions are dormant). The
        # proc is lazy — LineInput only resolves the root + shells out on the
        # first `@`, then caches. Same root rule as Tools::Base#workspace_root.
        files  = -> { Rubino.configuration.dig("terminal", "cwd") || Dir.pwd }
        line_input.configure_completion(commands: names.uniq, files: files)
      end

      def readline_input(line_input_or_prompt, prompt = nil, initial: nil)
        if prompt.nil?
          Rubino::UI::LineInput.new.readline(line_input_or_prompt, initial: initial)
        else
          line_input_or_prompt.readline(prompt, initial: initial)
        end
      end

      # --- Helpers ---

      def opt(key)
        @options[key] || @options[key.to_s]
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

        $stderr.puts "model: #{model_name}"
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

        $stderr.puts "rubino: warning: model '#{id}' is not in the known model catalog " \
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

      # Resolves which session this invocation should run against. +auto_resume+
      # enables the bare-`chat` auto-resume (#99) — only the interactive REPL
      # opts in; one-shot (`-q`/scripted) keeps the old "fresh unless asked"
      # behaviour so automation isn't silently hijacked onto a past session.
      def resolve_session_id(auto_resume: false)
        id = opt(:session)
        return id if id

        resume = opt(:resume) || opt(:r)
        return resume if resume

        if opt(:continue) || opt(:c)
          return Session::Repository.new.latest_active&.dig(:id)
        end

        # --new forces a brand-new session; otherwise a BARE interactive `chat`
        # auto-resumes the most recent resumable session so a user who closed
        # the terminal continues where they left off. nil ⇒ no prior session
        # (true first run) ⇒ fresh session + welcome panel.
        return nil if opt(:new) || !auto_resume

        @auto_resumed_session = Session::Repository.new.latest_resumable
        @auto_resumed_session&.dig(:id)
      end

      # True when the chat was started against an existing session (--resume /
      # --continue / explicit --session / bare-chat auto-resume): show its
      # history rather than the first-run welcome panel.
      def resuming_session?
        !!(opt(:session) || opt(:resume) || opt(:r) || opt(:continue) || opt(:c) ||
           @auto_resumed_session)
      end

      # Rebuilds the runner on a chosen session (the /sessions in-chat resume)
      # and replays its history so the transcript matches what was there before.
      def resume_runner(ui, session_id)
        runner = Agent::Runner.new(
          session_id:        session_id,
          model_override:    model_name,
          provider_override: opt(:provider),
          max_turns:         max_turns_override,
          ignore_rules:      opt(:ignore_rules) || false,
          ui:                ui
        )
        print_session_history(ui, runner.session[:id])
        runner
      end

      # Builds a runner on a brand-new session (the in-chat `/new`), without
      # passing any session_id so the runner creates a fresh one.
      def fresh_runner(ui)
        Agent::Runner.new(
          session_id:        nil,
          model_override:    model_name,
          provider_override: opt(:provider),
          max_turns:         max_turns_override,
          ignore_rules:      opt(:ignore_rules) || false,
          ui:                ui
        )
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
          $stderr.puts "fake provider is dev-only — set RUBINO_ALLOW_FAKE=1 to opt in."
          exit(1)
        end

        # Without this the tool registry stays empty, Lifecycle#load_tools
        # returns [], no `tools: [...]` is sent on the wire, and the model
        # has no choice but to roleplay bash in markdown. Symptom verified
        # via RUBYLLM_DEBUG=1 — request body was missing `tools` entirely.
        Rubino::Tools::Registry.register_defaults! if Rubino::Tools::Registry.all.empty?

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

        $stderr.puts LLM::CredentialCheck.missing_key_message
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

      # First-run guard. A brand-new user who runs `chat` before `setup` used
      # to hit a raw `SQLite3::SQLException: no such table: sessions` stack
      # trace: `database.healthy?` only runs `SELECT 1`, which succeeds the
      # moment SQLite lazily creates an empty file — the schema is still
      # missing (F2). Detect the un-migrated DB and auto-initialize (create the
      # home dirs + run migrations); migrations are idempotent, so this is safe
      # to run every boot. Only fall back to a friendly "run setup" message if
      # the auto-init itself fails, never a Ruby backtrace.
      def ensure_database_ready!
        connection = Rubino.database
        migrator   = Database::Migrator.new(connection)

        return unless connection.healthy? == false || migrator.pending?

        Rubino.ensure_directories!
        migrator.migrate!
      rescue StandardError => e
        Rubino.logger.debug(event: "auto_setup_failed", error: "#{e.class}: #{e.message}")
        $stderr.puts "rubino isn't set up yet — run `rubino setup` first."
        exit(1)
      end
    end
  end
end
