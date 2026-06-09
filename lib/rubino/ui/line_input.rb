# frozen_string_literal: true

require "reline"
require_relative "reline_dropdown_nav"

module Rubino
  module UI
    # Small terminal line editor wrapper for the (legacy) interactive Reline
    # prompt. Completion discovery + token highlight are delegated to the shared
    # UI::CompletionSource so the bottom composer and this path stay in sync; this
    # class only adapts that to Reline's completion_proc / output_modifier_proc.
    class LineInput
      # Re-exported for tests / callers that referenced the old constant.
      MAX_CANDIDATES = CompletionSource::MAX_CANDIDATES

      def initialize(history: Reline::HISTORY)
        @history = history
      end

      # `files:` is a lazy proc returning the workspace-root path to scan; the
      # actual file list is discovered + memoized on the first `@` keystroke
      # (inside the shared CompletionSource).
      def configure_completion(commands:, files: nil)
        @source = CompletionSource.new(commands: commands, files: files)

        Reline.completion_proc = proc do |input|
          @source.candidates_for(input)
        end
        # Render candidates as the inline fish-style dropdown menu rather than
        # plain tab-completion. `/` and `@` are not Reline word-break chars, so
        # the trigger char is preserved in the token handed to completion_proc.
        Reline.autocompletion = true
        Reline.completion_append_character = " "
        # Case-insensitive prefix matching for the @file picker (and commands).
        # The Readline-compat accessor sets @config.completion_ignore_case,
        # which is what Reline's candidate filter actually consults.
        Reline.completion_case_fold = true

        bind_dropdown_navigation

        Reline.output_modifier_proc = method(:highlight_line) if $stdout.tty?
      end

      # `initial:` seeds the editable line with text the user had already typed
      # but not yet submitted — e.g. a draft typed into the bottom composer
      # *during* a turn, carried over so it isn't lost when the turn ends and we
      # fall back to this cooked prompt. We pre-fill via Reline's Readline-compat
      # +pre_input_hook+ + +insert_text+ (cursor lands at the end, fully
      # editable). The hook is reset every call so a later prompt with no initial
      # starts empty.
      #
      # The hook is timing-fragile: when a long completion turn runs between the
      # idle composer handing the draft back and this prompt opening, Reline
      # intermittently opens the read loop without firing the hook, silently
      # dropping the draft (F1-residual: ~1/3 losses, all on a long turn). To make
      # the carry-over DETERMINISTIC we record whether the hook actually fired and,
      # if it did not (and the user didn't type the draft themselves), prepend the
      # draft to the returned line so it is never lost regardless of Reline timing.
      def readline(prompt, initial: nil)
        $stdout.puts
        $stdout.flush

        seed       = initial.to_s
        seed       = nil if seed.empty?
        hook_fired = false
        Reline.pre_input_hook = prefill_hook(seed) { hook_fired = true }
        line = Reline.readline(prompt, false)
        line = ensure_seeded(line, seed) unless hook_fired
        remember(line)
        line
      rescue Interrupt
        nil
      ensure
        Reline.pre_input_hook = nil
      end

      private

      # Builds a one-shot pre_input_hook that inserts +initial+ into the line
      # buffer once the prompt is up, or nil when there's nothing to seed. The
      # +fired+ block records that Reline actually invoked the hook, so the caller
      # can fall back to a deterministic prepend when it didn't.
      def prefill_hook(initial, &on_fire)
        return nil if initial.nil? || initial.to_s.empty?

        lambda do
          on_fire&.call
          Reline.insert_text(initial.to_s)
        end
      end

      # Deterministic fallback for when Reline opened the read loop WITHOUT firing
      # the pre_input_hook (so the seed never reached the buffer). If the returned
      # line already carries the seed (the user typed past it, or some other path
      # inserted it) we leave it alone; otherwise we prepend the seed so the
      # half-typed draft survives. nil (Ctrl-C / EOF) is returned untouched.
      def ensure_seeded(line, seed)
        return line if seed.nil? || line.nil?
        return line if line.start_with?(seed)

        "#{seed}#{line}"
      end

      # Bind the arrow keys to the dropdown-aware actions defined by
      # RelineDropdownNav (prepended into Reline::LineEditor). We go through the
      # SUPPORTED public `config.bind_key` API rather than patching a keymap:
      # bind_key parses the keyseq and stores it in @additional_key_bindings,
      # which survives terminfo's lazy default-keymap init (rubish relies on
      # this exact property). Both CSI (\e[A/B) and SS3/application-cursor
      # (\eOA/B) variants are bound. Tab (native `complete`) and Enter stay
      # untouched.
      def bind_dropdown_navigation
        cfg = Reline.core.config
        return unless cfg.respond_to?(:bind_key)

        cfg.bind_key('"\e[A"', "completion_or_up")
        cfg.bind_key('"\e[B"', "completion_or_down")
        cfg.bind_key('"\eOA"', "completion_or_up")
        cfg.bind_key('"\eOB"', "completion_or_down")
        # ESC dismisses the autocomplete dropdown without committing the arrowed
        # candidate (L8). A bare ESC is the CSI prefix, but Reline resolves a
        # lone ESC (no following bytes) to this action.
        cfg.bind_key('"\e"', "dismiss_completion_dialog")
        # Shift+Tab cycles the agent mode and Ctrl+O reveals the last reasoning
        # at the idle prompt too — additive bindings routed through the
        # IdleKeyActions registry to the SAME handlers the in-turn composer uses.
        # Shift+Tab is the CSI "back-tab" sequence \e[Z; Ctrl+O is byte 0x0f
        # (the \C-o token Reline parses to [15]). Both are additive: Tab
        # (native `complete`), Enter, editing, and history stay untouched.
        cfg.bind_key('"\e[Z"', "rubino_cycle_mode")
        cfg.bind_key('"\C-o"', "rubino_reveal_reasoning")
      rescue StandardError
        # Never let a binding hiccup take down the prompt — without it the
        # arrows simply fall back to native history navigation.
        nil
      end

      # Subtly colorize a leading /command or @mention token. Reline calls this
      # as `proc.call(line, complete:)`; the kwarg is ignored. Delegates to the
      # shared CompletionSource so the composer and this prompt highlight alike.
      def highlight_line(line, **)
        return line unless @source

        @source.highlight_line(line)
      end

      def remember(line)
        return if line.nil?

        stripped = line.strip
        return if stripped.empty? || @history.to_a.last == stripped

        @history.push(stripped)
      end
    end
  end
end
