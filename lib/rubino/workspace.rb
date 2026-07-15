# frozen_string_literal: true

module Rubino
  # The set of directory roots the agent is allowed to work in.
  #
  # Historically rubino had exactly ONE root, resolved at launch from
  # terminal.cwd or Dir.pwd, and every tool re-derived it. This module turns
  # that single root into an ordered SET of roots: the primary (launch) root
  # plus any directories added via `--add-dir` / `/add-dir`. The default — no
  # extra dirs — is byte-identical to the old single-root behaviour.
  #
  # Modelled on Claude Code's `--add-dir`: extra roots widen the write/edit
  # sandbox (see Tools::Base#within_workspace?) so the agent can touch files
  # under any allowed root, e.g. a service and its client library at once.
  module Workspace
    @added = []
    @mutex = Mutex.new

    class << self
      # The primary root: terminal.cwd when set, else the process cwd. This is
      # the same rule Tools::Base#workspace_root has always used, kept as the
      # single source of truth so the @-picker, shell/test cwd, file API and
      # attachment downloader all agree on "the" root.
      #
      # terminal.cwd MUST resolve to a String path: a malformed config (e.g. a
      # YAML `terminal: { cwd: { ... } }` nested mapping) would otherwise hand a
      # Hash to File.expand_path downstream, which raises "no implicit conversion
      # of Hash into String" deep in a tool's #call — masking the real outcome
      # (e.g. a write-denylist refusal) behind an opaque error. Anything that
      # isn't a non-empty String degrades to the process cwd.
      def primary_root
        configured = Rubino.configuration&.dig("terminal", "cwd")
        configured.is_a?(String) && !configured.empty? ? configured : Dir.pwd
      end

      # Every allowed root: the primary first, then each added dir, de-duped on
      # canonical path so re-adding the launch dir (or the same dir twice) is a
      # no-op. Returns plain strings.
      def roots
        @mutex.synchronize do
          ordered = [primary_root, *@added]
          seen = Set.new
          ordered.filter_map do |dir|
            real = canonical(dir)
            next unless real
            next if seen.include?(real)

            seen << real
            dir
          end
        end
      end

      # Canonical (realpath, symlinks resolved) form of every root — what the
      # sandbox compares against.
      def canonical_roots
        roots.filter_map { |dir| canonical(dir) }
      end

      # Adds an extra allowed root. Returns the canonical path on success, or
      # raises ArgumentError with a human-readable reason when the dir doesn't
      # exist / isn't a readable directory. realpath-resolves so a symlinked
      # add-dir lands on its true destination (and matches the sandbox check).
      def add(dir)
        expanded = File.expand_path(dir.to_s)
        raise ArgumentError, "no such directory: #{dir}" unless File.directory?(expanded)
        raise ArgumentError, "not readable: #{dir}" unless File.readable?(expanded)

        real = File.realpath(expanded)
        @mutex.synchronize do
          @added << real unless @added.include?(real) || canonical(primary_root) == real
        end
        real
      end

      # The SESSION current working directory — the single source of truth for
      # "where am I right now". Relative file paths (read/write/edit/
      # grep/glob, via Tools::Base#expand_workspace_path) and bare
      # foreground shell commands all anchor here, so a `cd subdir` in the shell
      # is honoured by every subsequent tool, not just the next shell call
      # (#544/#545).
      #
      # Defaults to primary_root. The shell sets it on `cd` (and resets it to
      # primary_root when a command wanders OUTSIDE the workspace).
      #
      # Stored THREAD-LOCAL on purpose: the parent agent loop runs on one thread
      # (its cwd persists across calls), while every subagent runs in its own
      # Thread (TaskTool#thread) and every background runner is its own thread —
      # so a subagent/background runner reads a fresh nil and starts at
      # primary_root, never inheriting the parent's cwd (subagent isolation). A
      # process-wide ivar would WRONGLY share one cwd across the parent and all
      # concurrent subagents.
      def current_cwd
        Thread.current[:rubino_session_cwd] || primary_root
      end

      # Sets the session cwd. Within the workspace sandbox the path is adopted
      # as-is; in strict mode a path OUTSIDE every allowed root is refused and
      # the cwd falls back to primary_root (the shell's soft-boundary reset). A
      # nil/empty/non-directory path also resets to primary_root.
      def current_cwd=(path)
        str = path.to_s
        Thread.current[:rubino_session_cwd] =
          if str.empty? || !File.directory?(str) || (workspace_strict? && !within_roots?(str))
            nil
          else
            str
          end
      end

      # Test/teardown hook: drop all added roots AND clear this thread's session
      # cwd (the primary is always derived live from config/cwd, so it can't be
      # reset here).
      def reset!
        @mutex.synchronize { @added = [] }
        reset_cwd!
      end

      # Clears ONLY the thread-local session cwd, leaving added roots intact.
      # Used by the global spec before-hook so a `cd` (or a direct current_cwd=)
      # on the main thread doesn't leak into the next example, WITHOUT wiping
      # roots an `around`/`before` set up for that example.
      def reset_cwd!
        Thread.current[:rubino_session_cwd] = nil
      end

      private

      # True when +path+ canonically resolves under any allowed root. Mirrors
      # Tools::Base#within_workspace? but kept here so the cwd setter can self-
      # validate without a Tools::Base instance.
      def within_roots?(path)
        real = canonical(path)
        return false unless real

        canonical_roots.any? do |root_real|
          real == root_real || real.start_with?("#{root_real}#{File::SEPARATOR}")
        end
      end

      def workspace_strict?
        Rubino.configuration&.dig("tools", "workspace_strict") != false
      rescue StandardError
        true
      end

      def canonical(path)
        return nil if path.nil? || path.to_s.empty?

        File.realpath(File.expand_path(path.to_s))
      rescue StandardError
        nil
      end
    end
  end
end
