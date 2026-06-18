# frozen_string_literal: true

require "reline"

module Rubino
  module UI
    # Prompt history for the bottom composer, backed by the SAME store the old
    # Reline idle prompt used (+Reline::HISTORY+) so continuity is preserved when
    # the composer becomes the single idle input path — a session's earlier
    # entries (and anything Reline itself recorded) stay navigable.
    #
    # Navigation model mirrors a shell / Reline: ↑ walks BACK toward older
    # entries, ↓ walks FORWARD toward newer ones and finally back to the live
    # draft the user was typing. The in-progress draft is stashed on the first ↑
    # so ↓-ing all the way down restores exactly what the user had typed, never
    # losing it.
    #
    # Like +LineInput#remember+, consecutive duplicates are de-duped on push so a
    # repeated command doesn't clutter the ring.
    #
    # PERSISTENCE (#2): like a shell (bash/zsh) and Hermes — which persists its
    # input history to a +.hermes_history+ file (see hermes_cli/profiles.py /
    # profile_distribution.py) — rubino persists submitted lines to a plain-text
    # file under RUBINO_HOME (default +<RUBINO_HOME>/history+, one entry per
    # line) so they survive a restart. The file is LOADED into the ring at
    # construction (composer/REPL startup) and each remembered line is APPENDED,
    # capped to the last {DEFAULT_CAP} entries. EVERYTHING submitted is recorded
    # — real prompts AND slash commands (/help, /agents, …) — matching the field
    # standard (bash/zsh/Claude Code) where ↑ recalls the whole input line. All
    # disk access is best-effort: a missing, unreadable or unwritable history
    # file must never crash startup or a turn, so every file op is rescued and
    # the in-memory ring keeps working.
    class InputHistory
      # Default number of most-recent entries kept on disk (and trimmed to on
      # save). A shell-sized ring: large enough to recall across sessions,
      # bounded so the file can't grow without limit.
      DEFAULT_CAP = 1000

      # Resolve the default history file under the SAME home the rest of rubino
      # uses (RUBINO_HOME → ~/.rubino, via the config Loader), so an isolated or
      # relocated home keeps its own history alongside config/.env/skills.
      def self.default_path
        File.join(Rubino::Config::Loader.default_home_path, "history")
      rescue StandardError
        nil
      end

      # @param store [#push, #to_a] the in-memory history ring (Reline::HISTORY
      #   by default, for continuity with the old idle prompt).
      # @param path [String, nil, :default] the on-disk history file. When left
      #   :default, persistence is tied to the DEFAULT global store: the real
      #   chat ring (Reline::HISTORY) persists to <RUBINO_HOME>/history, while an
      #   INJECTED private store (tests / standalone) stays purely in-memory — so
      #   a private ring never reads/writes the shared file. Pass an explicit
      #   path to force persistence, or nil to force it off.
      # @param cap [Integer] most-recent entries kept on disk.
      def initialize(store: Reline::HISTORY, path: :default, cap: DEFAULT_CAP)
        @store  = store
        @path   = if path == :default
                    store.equal?(Reline::HISTORY) ? self.class.default_path : nil
                  else
                    path
                  end
        @cap    = cap
        # Cursor into the history ring. nil = "on the live draft" (not navigating
        # history). 0 = most recent entry, increasing = older.
        @index  = nil
        @draft  = nil
        load_from_disk
      end

      # Append a submitted line, de-duping a consecutive duplicate (matches
      # LineInput#remember). Blank lines are not recorded. Resets navigation so
      # the next ↑ starts from the newest entry again. EVERYTHING typed is
      # recorded — real prompts AND slash commands — so ↑ recalls the whole
      # input line like bash/zsh/Claude Code (#2). Also appended to the on-disk
      # history (best-effort) so it survives a restart.
      def remember(line)
        reset!
        return if line.nil?

        stripped = line.strip
        return if stripped.empty? || last == stripped

        @store.push(stripped)
        append_to_disk(stripped)
      end

      # Move toward OLDER entries (↑). +current+ is the buffer the user is
      # editing right now; it's stashed as the draft on the first move up so ↓
      # can restore it. Returns the entry to show, or nil when there's nothing
      # older (caller keeps the current buffer).
      def up(current)
        entries = to_a
        return nil if entries.empty?

        if @index.nil?
          # dup, not to_s: String#to_s returns self, so a later in-place
          # @buffer.replace by the caller would mutate the stashed draft too.
          @draft = current.to_s.dup
          @index = 0
        elsif @index < entries.size - 1
          @index += 1
        else
          return nil # already on the oldest entry — clamp
        end
        entries[entries.size - 1 - @index]
      end

      # Move toward NEWER entries (↓). Returns the newer entry, or the stashed
      # draft when stepping back below the newest entry, or nil when not
      # currently navigating history (caller keeps the current buffer).
      def down(_current = nil)
        return nil if @index.nil?

        entries = to_a
        if @index.positive?
          @index -= 1
          entries[entries.size - 1 - @index]
        else
          # Stepped below the newest entry → back to the live draft.
          @index = nil
          d = @draft.to_s
          @draft = nil
          d
        end
      end

      # True while the cursor is walking the history ring (not on the draft).
      def navigating?
        !@index.nil?
      end

      # Drop navigation state (called on submit / any direct edit so a fresh ↑
      # starts from the newest entry and a typed edit isn't treated as history).
      def reset!
        @index = nil
        @draft = nil
      end

      private

      # Load the persisted ring into the in-memory store at startup. Best-effort:
      # a missing/unreadable file (or any read error) leaves the ring untouched
      # and never raises. Only the last @cap lines are loaded; consecutive
      # duplicates and blanks are skipped to mirror #remember's contract.
      def load_from_disk
        return unless @path && File.exist?(@path)

        File.foreach(@path).map(&:chomp).last(@cap).each do |line|
          stripped = line.strip
          next if stripped.empty? || last == stripped

          @store.push(stripped)
        end
      rescue StandardError
        # Best-effort: a corrupt/unreadable history file must never block boot.
        nil
      end

      # Append one submitted line to the on-disk history, then trim the file to
      # the last @cap entries. Best-effort: an unwritable/missing-parent path (or
      # any write error) is swallowed so a turn never crashes on history I/O.
      def append_to_disk(line)
        return unless @path

        File.open(@path, "a") { |f| f.puts(line) }
        trim_disk
      rescue StandardError
        nil
      end

      # Cap the on-disk file to the last @cap lines so it can't grow without
      # bound. Rewrites only when over the cap; best-effort like the rest.
      def trim_disk
        lines = File.readlines(@path)
        return if lines.size <= @cap

        File.write(@path, lines.last(@cap).join)
      rescue StandardError
        nil
      end

      def to_a
        @store.respond_to?(:to_a) ? @store.to_a : Array(@store)
      end

      def last
        to_a.last
      end
    end
  end
end
