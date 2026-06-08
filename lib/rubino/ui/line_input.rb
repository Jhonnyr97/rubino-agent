# frozen_string_literal: true

require "reline"
require "pastel"
require "open3"
require_relative "reline_dropdown_nav"

module Rubino
  module UI
    # Small terminal line editor wrapper for interactive CLI input.
    # Keeps prompt rendering, history, and completion in one place.
    class LineInput
      # Tokens that trigger highlighting at the start of the line.
      TRIGGER_TOKEN = %r{\A([/@]\S+)}

      # Cap on candidates handed to the dropdown — keeps the menu skimmable
      # and bounds work on huge repos. Cline et al. ship similar caps.
      MAX_CANDIDATES = 30

      # How long a computed file list stays warm before the next `@` reshells.
      # Long enough to span a burst of keystrokes, short enough that a file
      # created mid-session shows up without restarting the prompt.
      FILE_CACHE_TTL = 5.0

      # Hardcoded ignore set for the last-resort Dir.glob walk (git/rg already
      # honor .gitignore; this is only the fallback's safety net).
      GLOB_IGNORE_DIRS = %w[.git node_modules vendor tmp log .bundle].freeze

      # Hard ceiling on the Dir.glob fallback so a giant tree can't hang the
      # prompt while we walk it.
      GLOB_MAX_FILES = 5000

      def initialize(history: Reline::HISTORY)
        @history = history
        @pastel = Pastel.new
      end

      # `files:` is a lazy proc returning the workspace-root path to scan; the
      # actual file list is discovered + memoized on the first `@` keystroke.
      def configure_completion(commands:, files: nil)
        @files_root_proc = files

        Reline.completion_proc = proc do |input|
          candidates_for(input, commands: commands)
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
      rescue StandardError
        # Never let a binding hiccup take down the prompt — without it the
        # arrows simply fall back to native history navigation.
        nil
      end

      def candidates_for(input, commands:)
        case input
        when /\A\//
          commands.select { |command| command.start_with?(input) }
        when /\A@/
          file_candidates(input)
        else
          []
        end
      end

      # Turn an `@<partial>` token into `@<relpath>` candidates.
      #
      # Reline filters candidates with `start_with?(target)` where target is the
      # full token (incl. the leading `@`, since `/` and `@` aren't word-break
      # chars). So the emitted string must itself start with `@<partial>`; we
      # therefore prefix-match on the relative path. MVP is prefix-only (no true
      # fuzzy — Cline ships prefix-only too). Selection replaces the token with
      # `@<relpath> `; the model then reads that literal path via the `read`
      # tool. Case-insensitivity comes from Reline.completion_ignore_case.
      def file_candidates(input)
        partial = input.sub(/\A@/, "")
        down    = partial.downcase

        workspace_files
          .lazy
          .select { |rel| rel.downcase.start_with?(down) }
          .map { |rel| "@#{rel}" }
          .first(MAX_CANDIDATES)
      end

      # Workspace-relative file list, discovered once per `@` burst and memoized
      # for FILE_CACHE_TTL so we never reshell on every keystroke.
      def workspace_files
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @files_cache && @files_cache_at && (now - @files_cache_at) < FILE_CACHE_TTL
          return @files_cache
        end

        @files_cache    = discover_files(workspace_root)
        @files_cache_at = now
        @files_cache
      end

      # Same source of truth as Tools::Base#workspace_root (the primary root).
      def workspace_root
        root = @files_root_proc&.call if @files_root_proc
        root || Rubino::Workspace.primary_root
      rescue StandardError
        Dir.pwd
      end

      # Ignore-aware file discovery, fastest-first. Any failure at a tier falls
      # through; if everything fails we return [] and the prompt keeps working.
      def discover_files(root)
        return [] unless root && File.directory?(root)

        git_files(root) || rg_files(root) || glob_files(root) || []
      rescue StandardError
        []
      end

      # (1) git: tracked + untracked, honoring .gitignore, no FS walk of our own.
      # nil (not []) on failure so the caller falls through to the next tier.
      def git_files(root)
        out, status = Open3.capture2(
          "git", "ls-files", "--cached", "--others", "--exclude-standard",
          chdir: root
        )
        return nil unless status.success?

        out.split("\n").reject(&:empty?)
      rescue StandardError
        nil
      end

      # (2) ripgrep: --files lists every file rg would search (also .gitignore
      # aware). Only attempted when rg is on PATH.
      def rg_files(root)
        return nil unless ripgrep_available?

        out, status = Open3.capture2("rg", "--files", chdir: root)
        return nil unless status.success?

        out.split("\n").reject(&:empty?)
      rescue StandardError
        nil
      end

      def ripgrep_available?
        system("which rg > /dev/null 2>&1")
      end

      # (3) last resort: a capped, ignore-aware Dir.glob walk. Best-effort
      # .gitignore is NOT consulted here — we lean on GLOB_IGNORE_DIRS plus the
      # count cap. Only reached when neither git nor rg is usable.
      def glob_files(root)
        files = []
        Dir.glob("**/*", File::FNM_DOTMATCH, base: root) do |rel|
          next if rel == "." || rel == ".."
          next if GLOB_IGNORE_DIRS.any? { |d| rel == d || rel.start_with?("#{d}/") }
          next unless File.file?(File.join(root, rel))

          files << rel
          break if files.size >= GLOB_MAX_FILES
        end
        files
      rescue StandardError
        nil
      end

      # Subtly colorize a leading /command or @mention token. Reline calls this
      # as `proc.call(line, complete:)`; the kwarg is ignored. Plain text and
      # non-strings are returned unchanged.
      def highlight_line(line, **)
        return line unless line.is_a?(String)

        line.sub(TRIGGER_TOKEN) { @pastel.cyan(Regexp.last_match(1)) }
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
