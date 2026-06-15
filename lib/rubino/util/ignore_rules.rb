# frozen_string_literal: true

require "open3"
require "set"

module Rubino
  module Util
    # Consistent .gitignore-aware file filtering shared by the grep Ruby
    # fallback and the glob tool (#375b/#375c).
    #
    # The PROBLEM: grep's ripgrep path honors .gitignore, but the Ruby fallback
    # (`Dir.glob("**/*")`) did not — so `grep` returned a DIFFERENT, larger set
    # (including build artifacts, node_modules, secrets in ignored files)
    # depending on whether rg happened to be installed. Non-deterministic, and a
    # leak of ignored content. The glob tool ignored .gitignore entirely too.
    #
    # The FIX: a single ignore oracle both non-rg paths consult, matching rg's
    # default semantics as closely as a non-rg implementation can:
    #
    #   * In a git repo, the canonical answer is `git ls-files --cached --others
    #     --exclude-standard` (tracked + untracked-but-not-ignored) — EXACTLY
    #     the set rg searches by default. We build the allowed-path set from it.
    #   * Outside a repo (or if git fails), fall back to a small built-in
    #     denylist of always-noise dirs (.git, node_modules, …) so behaviour is
    #     still deterministic and never leaks the VCS internals.
    #
    # Per-root results are cached for the life of the instance, so a single
    # grep/glob call pays the git cost once.
    class IgnoreRules
      # Always-skipped dirs for the non-git fallback. Mirrors the set
      # UI::CompletionSource uses so discovery is consistent across the tool.
      FALLBACK_IGNORE_DIRS = %w[.git node_modules vendor tmp log .bundle .svn .hg __pycache__].freeze

      def initialize
        @allowed_cache = {}
        @git_root_cache = {}
      end

      # True when +abs_path+ (an absolute file path) should be EXCLUDED from
      # results given +root+ (the search base). Consistent across grep-fallback
      # and glob: a path git ignores (or the fallback denylist matches) is
      # ignored regardless of whether rg is installed.
      def ignored?(abs_path, root)
        allowed = allowed_set(root)
        return fallback_ignored?(abs_path, root) if allowed.nil?

        rel = relative(abs_path, root)
        return true if rel.nil?

        !allowed.include?(rel)
      end

      private

      # The set of NON-ignored relative paths under +root+ per git, or nil when
      # this isn't a git repo / git failed (caller falls back to the denylist).
      # git ls-files is run from the repo root and paths are re-based onto +root+
      # so a search rooted in a subdir still matches.
      def allowed_set(root)
        @allowed_cache.fetch(root) do
          @allowed_cache[root] = build_allowed_set(root)
        end
      end

      def build_allowed_set(root)
        repo_root = git_root(root)
        return nil if repo_root.nil?

        out, status = Open3.capture2(
          "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z",
          chdir: repo_root, err: File::NULL
        )
        return nil unless status.success?

        set = Set.new
        out.split("\0").each do |rel_to_repo|
          next if rel_to_repo.empty?

          abs = File.expand_path(rel_to_repo, repo_root)
          rel = relative(abs, root)
          set << rel if rel
        end
        set
      rescue StandardError
        nil
      end

      # The git toplevel for +root+, or nil if not a repo. Cached per root.
      def git_root(root)
        @git_root_cache.fetch(root) do
          out, status = Open3.capture2(
            "git", "rev-parse", "--show-toplevel",
            chdir: root, err: File::NULL
          )
          @git_root_cache[root] = status.success? ? out.strip : nil
        end
      rescue StandardError
        @git_root_cache[root] = nil
      end

      # Non-git fallback: ignore by built-in noise-dir denylist on any path
      # component, so behaviour stays deterministic without a repo.
      def fallback_ignored?(abs_path, root)
        rel = relative(abs_path, root) || File.basename(abs_path)
        rel.split(File::SEPARATOR).any? { |part| FALLBACK_IGNORE_DIRS.include?(part) }
      end

      # Path of +abs_path+ relative to +root+, or nil when it's outside +root+.
      def relative(abs_path, root)
        abs  = File.expand_path(abs_path)
        base = File.expand_path(root)
        return File.basename(abs) if abs == base

        prefix = "#{base}#{File::SEPARATOR}"
        return nil unless abs.start_with?(prefix)

        abs[prefix.length..]
      end
    end
  end
end
