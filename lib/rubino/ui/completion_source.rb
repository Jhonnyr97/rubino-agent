# frozen_string_literal: true

require "pastel"
require "open3"

module Rubino
  module UI
    # Shared completion DISCOVERY + token HIGHLIGHT for the interactive prompt.
    # The bottom composer's /command + @file completion menu and token highlight
    # consult this single implementation (git→rg→glob walk, @file candidate
    # shaping, caps/TTL cache, cyan leading-token highlight) instead of each
    # path duplicating it.
    #
    #   * +candidates_for(token)+ — slash commands or @file paths for a token.
    #   * +highlight_line(line)+  — cyan the leading /command / @mention token.
    #
    # Discovery is fastest-first (git tracked+untracked honoring .gitignore →
    # ripgrep --files → a capped Dir.glob walk) and memoized for a few seconds so
    # a burst of @ keystrokes never reshells. Every tier is guarded so a failure
    # degrades to the next tier (and finally to []), never crashing the prompt.
    class CompletionSource
      # Tokens that trigger highlighting at the start of the line. A leading
      # `!` (the bang shell escape) glows like `/` so the user can SEE the
      # line will run as a shell command, not a message — highlight only, it
      # never opens the completion menu.
      TRIGGER_TOKEN = %r{\A([/@]\S+|!\S*)}

      # Cap on candidates — keeps the menu skimmable and bounds work on huge
      # repos. Cline et al. ship similar caps.
      MAX_CANDIDATES = 30

      # How long a computed file list stays warm before the next `@` reshells.
      FILE_CACHE_TTL = 5.0

      # Hardcoded ignore set for the last-resort Dir.glob walk (git/rg already
      # honor .gitignore; this is only the fallback's safety net).
      GLOB_IGNORE_DIRS = %w[.git node_modules vendor tmp log .bundle].freeze

      # Hard ceiling on the Dir.glob fallback so a giant tree can't hang the
      # prompt while we walk it.
      GLOB_MAX_FILES = 5000

      # The `✗ none` clear entry shown at the TOP of an argument list whose
      # command supports clearing its active selection (e.g. `/skills`). Picking
      # it submits the bare sentinel so the command handler clears the slot.
      NONE_ENTRY = "✗ none"

      # @param commands [Array<String>] the slash-command names (incl. leading /)
      # @param files [#call, nil] lazy proc returning the workspace root to scan
      # @param arg_sources [Hash{String=>#call}] maps a BARE command name (no
      #   leading slash, e.g. "skills") to a proc returning that command's
      #   argument candidates. Two shapes:
      #     * a NO-ARG proc — a single-argument command (e.g. "skills" → the
      #       skill names); only the FIRST argument completes, and the list is
      #       prefixed with the `✗ none` clear entry (NONE_ENTRY) so the picker
      #       can clear the active selection from the top.
      #     * a ONE-ARG proc — receives the PRIOR-argument array and decides
      #       what completes at this position (e.g. "agents": [] → live ids,
      #       [id] → steer/probe/--stop), so a subcommand grammar is
      #       discoverable from the same dropdown (#39). No `✗ none` entry is
      #       injected — but the source may INCLUDE the NONE_ENTRY string in
      #       its own list (e.g. "skills", whose first position mixes the
      #       activate-by-name list with the enable/disable verbs, #188), and
      #       it keeps the same special matching the no-arg shape gives it.
      #       Closed enums (`/mode`, `/reasoning`, `/think`, #185) use this
      #       shape too — `->(args) { args.empty? ? VALUES : [] }` — exactly
      #       because it carries no `✗ none` entry (there is no "clear" for a
      #       mode; the no-arg shape's prefix would offer a bogus value).
      #     * a TWO-ARG proc — receives (prior args, the PARTIAL typed so far)
      #       and OWNS the matching (no additional prefix filter): a
      #       filesystem-path source (`/add-dir`, #185) expands `~`, which a
      #       literal prefix filter would drop. No `✗ none` entry.
      # @param descriptions [Hash{String=>String}] one-line description per
      #   candidate string (e.g. BuiltIns::DESCRIPTIONS), rendered dim next to
      #   the name in the dropdown (#39). Candidates without an entry show
      #   bare, as before.
      def initialize(commands: [], files: nil, arg_sources: {}, descriptions: {})
        @commands        = Array(commands).uniq
        @files_root_proc = files
        @arg_sources     = arg_sources || {}
        @descriptions    = descriptions || {}
        @pastel          = Pastel.new
      end

      # Candidates for a completion token. A `/`-prefixed token completes from
      # the command list; an `@`-prefixed token completes from workspace files;
      # anything else has no candidates. Case-insensitive prefix matching.
      def candidates_for(token)
        case token
        when %r{\A/}
          down = token.downcase
          @commands.select { |c| c.downcase.start_with?(down) }
        when /\A@/
          file_candidates(token)
        else
          []
        end
      end

      # Candidates for the ARGUMENT of a command, e.g. the skill names when the
      # buffer is `/skills <partial>`. +command+ is the bare command name (no
      # leading slash); +partial+ is the text typed so far for the argument
      # (may be empty); +args+ the COMPLETE arguments typed before it. Returns
      # [] when the command has no registered argument source.
      #
      # Candidates are filtered by case-insensitive prefix and capped at
      # MAX_CANDIDATES — the SAME cap the `/command` and `@file` lists honor.
      # A no-arg source (single-argument command) completes only the first
      # argument and leads with the `✗ none` clear entry; a one-arg source is
      # called with +args+ and owns the per-position grammar (#39) — see
      # #initialize.
      def arg_candidates_for(command, partial, args = [])
        source = @arg_sources[command.to_s]
        return [] unless source

        down = partial.to_s.downcase
        list =
          if source.arity.zero?
            return [] unless args.empty? # single-argument command: first arg only

            # The `✗ none` clear entry matches an empty partial or a
            # "n"/"no…"/"none" prefix, so typing toward "none" keeps it in view.
            none = down.empty? || NONE.start_with?(down) ? [NONE_ENTRY] : []
            none + Array(source.call).select { |n| n.to_s.downcase.start_with?(down) }
          elsif source.arity == 2
            # PARTIAL-AWARE source: it derives candidates FROM the typed text
            # (e.g. a filesystem glob) and owns the matching — see #initialize.
            Array(source.call(args, partial.to_s))
          else
            positional_candidates(source.call(args), down)
          end
        list.first(MAX_CANDIDATES)
      end

      # Prefix-filtered candidates from a positional (one-arg) source. A
      # literal NONE_ENTRY in the source's list (the /skills first position,
      # #188) keeps the clear entry's special matching — shown on an empty
      # partial or while typing toward "none" — instead of being dropped by
      # the literal `✗ ` prefix filter.
      def positional_candidates(list, down)
        list     = Array(list)
        has_none = list.delete(NONE_ENTRY)
        matched  = list.select { |n| n.to_s.downcase.start_with?(down) }
        return matched unless has_none && (down.empty? || NONE.start_with?(down))

        [NONE_ENTRY] + matched
      end

      # Directory candidates for a PATH-shaped argument (`/add-dir `, #185) —
      # the directory-flavored sibling of the `@file` picker. Globs the
      # filesystem from the typed partial (relative to cwd, absolute, or
      # `~`-prefixed — an added root usually lives OUTSIDE the workspace, so
      # the workspace file list is the wrong source here), keeps only
      # directories, and folds `~` back so the spliced candidate preserves the
      # user's spelling. Best-effort: any failure (e.g. `~nouser`) returns [].
      def self.directory_candidates(partial)
        text    = partial.to_s
        pattern = text.start_with?("~") ? File.expand_path(text) : text
        Dir.glob("#{pattern}*")
           .select { |p| File.directory?(p) }
           .sort
           .map { |p| text.start_with?("~") ? p.sub(File.expand_path("~"), "~") : p }
           .first(MAX_CANDIDATES)
      rescue StandardError
        []
      end

      # The sentinel a `✗ none` selection resolves to once spliced + submitted —
      # the command handler treats this argument as "clear the active selection".
      NONE = "none"

      # The one-line description for a dropdown candidate (#39): the same
      # strings /help shows for a `/command`, a usage hint for a subcommand.
      # nil when the candidate has none (files, skill names) — the menu row
      # renders bare, exactly as before.
      def description_for(candidate)
        @descriptions[candidate.to_s]
      end

      # Subtly colorize a leading /command or @mention token (cyan). Plain text
      # and non-strings are returned unchanged. Matches LineInput#highlight_line.
      # A "[Pasted text #N +M lines]" paste placeholder (UI::PasteStore) glows
      # the same way wherever it sits in the line, so the user can SEE it is a
      # token that expands at send, not literal text.
      def highlight_line(line)
        return line unless line.is_a?(String)

        line.sub(TRIGGER_TOKEN) { @pastel.cyan(Regexp.last_match(1)) }
            .gsub(PasteStore::TOKEN_RE) { |token| @pastel.cyan(token) }
      end

      private

      # Turn an `@<partial>` token into `@<relpath>` candidates, prefix-matching
      # the relative path case-insensitively (MVP is prefix-only, as Cline ships).
      def file_candidates(token)
        partial = token.sub(/\A@/, "")
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
        return @files_cache if @files_cache && @files_cache_at && (now - @files_cache_at) < FILE_CACHE_TTL

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

      # (1) git: tracked + untracked, honoring .gitignore. nil (not []) on
      # failure so the caller falls through to the next tier. err: File::NULL so
      # git's "fatal: not a git repository" never bleeds onto the prompt (D5).
      def git_files(root)
        out, status = Open3.capture2(
          "git", "ls-files", "--cached", "--others", "--exclude-standard",
          chdir: root, err: File::NULL
        )
        return nil unless status.success?

        out.split("\n").reject(&:empty?)
      rescue StandardError
        nil
      end

      # (2) ripgrep: --files lists every file rg would search (.gitignore aware).
      def rg_files(root)
        return nil unless ripgrep_available?

        out, status = Open3.capture2("rg", "--files", chdir: root, err: File::NULL)
        return nil unless status.success?

        out.split("\n").reject(&:empty?)
      rescue StandardError
        nil
      end

      def ripgrep_available?
        system("which rg > /dev/null 2>&1")
      end

      # (3) last resort: a capped, ignore-aware Dir.glob walk.
      def glob_files(root)
        files = []
        Dir.glob("**/*", File::FNM_DOTMATCH, base: root) do |rel|
          next if [".", ".."].include?(rel)
          next if GLOB_IGNORE_DIRS.any? { |d| rel == d || rel.start_with?("#{d}/") }
          next unless File.file?(File.join(root, rel))

          files << rel
          break if files.size >= GLOB_MAX_FILES
        end
        files
      rescue StandardError
        nil
      end
    end
  end
end
