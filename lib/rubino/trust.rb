# frozen_string_literal: true

require "json"
require "fileutils"

module Rubino
  # Proportionate folder-trust, modelled on VS Code Workspace Trust and Claude
  # Code's directory-trust dialog — but DELIBERATELY lighter, because rubino
  # auto-RUNS no code from a project directory (config is HOME-only, there are
  # no folder-open hooks, custom slash commands are user-triggered, and the
  # arbitrary-Ruby tool loader can no longer load from cwd — see #44).
  #
  # What the gate protects: the ONE thing rubino auto-loads from a directory is
  # *text into the system prompt* — its AGENTS.md / CLAUDE.md / .rubino.md /
  # .cursorrules project-context files and its .rubino/skills catalogue. A
  # hostile repo can use those to STEER the agent (prompt injection) the moment
  # you start there. So, like VS Code's Restricted Mode, an untrusted directory
  # still works — it just runs WITHOUT that directory's project context and
  # skills until you vouch for it.
  #
  # What it does NOT do: there is no feature-disabling Restricted Mode (no
  # auto-executed code to disable) and no per-tool gating — that would be
  # ceremony without payoff given rubino's actual exposure.
  #
  # The decision is remembered in trusted_dirs.json under RUBINO_HOME so a
  # trusted directory is never re-prompted (mirrors trustedDirectories).
  module Trust
    FILENAME = "trusted_dirs.json"

    class << self
      # True when +dir+ has been remembered as trusted. Compares on canonical
      # (realpath) form so a symlinked/relative path matches its stored entry.
      def trusted?(dir)
        real = canonical(dir)
        return false unless real

        load_dirs.any? { |d| canonical(d) == real }
      end

      # Remembers +dir+ as trusted (idempotent). Stores the canonical path so
      # later lookups match regardless of how the dir is later referenced.
      def remember(dir)
        real = canonical(dir)
        return unless real

        dirs = load_dirs
        return if dirs.any? { |d| canonical(d) == real }

        save_dirs(dirs + [real])
      end

      # The remembered list, canonicalised (for display / tests).
      def trusted_dirs
        load_dirs
      end

      def store_path
        File.join(Rubino.home_path, FILENAME)
      end

      private

      def load_dirs
        return [] unless File.exist?(store_path)

        data = JSON.parse(File.read(store_path))
        data.is_a?(Array) ? data.map(&:to_s) : []
      rescue StandardError
        []
      end

      def save_dirs(dirs)
        FileUtils.mkdir_p(File.dirname(store_path))
        File.write(store_path, JSON.pretty_generate(dirs.uniq))
      rescue StandardError
        nil
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
