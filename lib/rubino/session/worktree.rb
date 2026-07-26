# frozen_string_literal: true

require "open3"
require "securerandom"
require "fileutils"

module Rubino
  module Session
    # Session-scoped git worktree isolation (`worktree.enabled`, config key
    # that shipped as a 100% dead stub — this class is the real implementation).
    #
    # Modelled on Hermes' `_setup_worktree` / `_cleanup_worktree`
    # (hermes-agent/cli.py), right-sized for rubino's simpler single-user CLI:
    #
    #   - Hermes' standalone clone (`~/.hermes/hermes-agent`) is refreshed only
    #     on `hermes update`, so its local HEAD can be hundreds of commits
    #     stale — branching a worktree from it silently rooted every session on
    #     an old base. Hermes fixed that by fetching the remote tip first
    #     (`_resolve_worktree_base`). Rubino has no such standalone clone: the
    #     worktree is created INSIDE the very repo the user is sitting in and
    #     launched rubino from, so the local HEAD *is* the freshest thing
    #     available — fetching a remote would, if anything, branch from a
    #     LESS relevant ref (another collaborator's push, or nothing at all in
    #     an offline/solo repo with no configured remote). So this
    #     deliberately branches from local HEAD, captured as a fixed SHA at
    #     setup time (see #setup!) — no fetch, no upstream resolution.
    #   - No lock (`git worktree lock`) and no age-based stale-worktree pruner
    #     (Hermes' #7, lower priority per the build brief) — left as a
    #     follow-up. A worktree from a killed process is simply left behind
    #     (see #cleanup! docs): an acceptable cost, never a corruption risk,
    #     since nothing here ever touches the user's real checkout.
    #   - No `.worktreeinclude` (copying gitignored files into the worktree) —
    #     not requested and adds real attack surface (path traversal /
    #     symlink-escape) for a feature nobody asked for yet.
    #   - The keep-or-discard decision on exit is commits-ahead-of-base, not
    #     Hermes' "unpushed commits" (which needs a remote to compare
    #     against) — simpler, and correct for a repo that may have no remote
    #     at all. There is NO code path here that pushes or merges the
    #     worktree branch anywhere, ever — only a human does that, via normal
    #     git, after reading the printed path/branch.
    class Worktree
      DIR_NAME = ".worktrees"
      GITIGNORE_ENTRY = ".worktrees/"

      class << self
        # The config-gated entry point, called once per session at boot —
        # BEFORE the agent loop (and any tool call) can touch a path — from
        # CLI::ChatCommand#setup_workspace_and_trust!, the same chokepoint
        # that seeds --add-dir roots and runs the folder-trust gate.
        #
        # Returns nil when `worktree.enabled` is not literally true — the
        # default, byte-identical-to-today path; nothing else in this class
        # runs, Workspace.primary_root is untouched. Returns a Worktree
        # instance whenever the feature is ON, whether or not the git
        # operation itself succeeded: #active? tells the two outcomes apart
        # so the caller can print either the "isolated in ..." notice or the
        # degrade notice (#notice) — a non-git launch dir, or any other git
        # failure, ALWAYS degrades to running with no isolation, never a crash.
        def setup!
          return nil unless Rubino.configuration.worktree_enabled?

          new.setup!
        end
      end

      attr_reader :path, :branch, :base_sha, :repo_root, :notice

      def initialize(launch_root: Rubino::Workspace.primary_root)
        @launch_root = launch_root
        @active = false
      end

      # True once #setup! has redirected Workspace.primary_root at an isolated
      # worktree. False when the feature is degraded (see #notice) — callers
      # must treat that exactly like worktree.enabled were false.
      def active?
        @active
      end

      # Creates `<repo_root>/.worktrees/rubino-<id>` on a new `rubino/<id>`
      # branch off the repo's CURRENT HEAD (captured as a fixed SHA, so a
      # commit landing in the user's real checkout DURING the session can
      # never move the base out from under the later ahead-count check),
      # appends `.worktrees/` to .gitignore, then redirects
      # Workspace.primary_root (via `terminal.cwd`, the SAME live-config seam
      # Tools::Base#workspace_root already reads) and appends an isolation
      # note to `prompts.preamble` (see NOTE_TEMPLATE) — both IN-MEMORY only,
      # never written to config.yml, and both restored by #cleanup!.
      #
      # Best-effort end to end: a non-git launch dir, an unborn/empty repo, a
      # missing git binary, or `git worktree add` refusing for any reason all
      # degrade to @active = false + a human-readable #notice, never an
      # exception out of session boot.
      def setup!
        @repo_root = git_toplevel(@launch_root)
        return degrade("'#{@launch_root}' is not inside a git repository") unless @repo_root

        id = SecureRandom.hex(4)
        @branch = "rubino/#{id}"
        @path = File.join(@repo_root, DIR_NAME, "rubino-#{id}")

        @base_sha = git_head_sha(@repo_root)
        return degrade("could not resolve HEAD in #{@repo_root} (empty/unborn repository?)") unless @base_sha

        FileUtils.mkdir_p(File.join(@repo_root, DIR_NAME))
        ensure_gitignore_entry!

        out, status = Open3.capture2e(
          "git", "worktree", "add", @path, "-b", @branch, @base_sha, chdir: @repo_root
        )
        return degrade("git worktree add failed: #{out.strip}") unless status.success?

        begin
          redirect_workspace!
          inject_prompt_note!
        rescue StandardError => e
          remove!
          return degrade("#{e.class}: #{e.message}")
        end

        @active = true
        self
      rescue StandardError => e
        degrade("#{e.class}: #{e.message}")
      end

      # Runs once, on a CLEAN session exit (the human quit normally, or a
      # one-shot run finished/errored/was interrupted through ordinary Ruby
      # control flow). Deliberately NOT wired into the SIGTERM/SIGHUP trap
      # handler (CLI::ChatCommand#install_session_end_traps) — that handler is
      # kept minimal on purpose (it must stay signal-trap-safe: no mutex, no
      # subprocess spawn) and a leftover un-pruned worktree from that path, or
      # from a harder `kill -9`, is an accepted cost (see the class doc) —
      # never a corruption risk, since nothing here touches the user's real
      # checkout, only the isolated linked worktree.
      #
      # No commits ahead of the captured base SHA ⇒ nothing of value was
      # created: SILENTLY removes the worktree + branch (returns
      # kept: false, no message — matches "silently" in the design brief).
      # Uncommitted/untracked files alone do NOT count — work lives in
      # commits, not the working tree (mirrors Hermes' rationale).
      #
      # One or more commits ahead ⇒ KEEPS both, and returns a human-facing
      # :message naming the exact path/branch and the `git` commands to
      # review/merge/discard it — reviewed and merged (or thrown away) by a
      # HUMAN via normal git; this method never merges or pushes anything.
      #
      # Restores terminal.cwd + prompts.preamble to their pre-session values
      # either way, so a spec (or any process that keeps running after this
      # session, e.g. under rspec) never leaks the redirect into what runs
      # next. Returns nil when never active (feature off, or setup degraded).
      def cleanup!
        return nil unless active?

        ahead = commits_ahead
        result =
          if ahead.positive?
            { kept: true, path: @path, branch: @branch, ahead: ahead, message: kept_message(ahead) }
          else
            remove!
            { kept: false, path: @path, branch: @branch, ahead: 0 }
          end

        restore_config!
        @active = false
        result
      end

      private

      def degrade(reason)
        @notice = "worktree.enabled is set, but isolation could not start (#{reason}) " \
                  "— continuing without a worktree, in the original checkout."
        @active = false
        self
      end

      def git_toplevel(dir)
        return nil unless dir && File.directory?(dir)

        out, status = Open3.capture2("git", "rev-parse", "--show-toplevel", chdir: dir, err: File::NULL)
        status.success? ? out.strip : nil
      rescue StandardError
        nil
      end

      def git_head_sha(repo_root)
        out, status = Open3.capture2("git", "rev-parse", "HEAD", chdir: repo_root, err: File::NULL)
        status.success? ? out.strip : nil
      rescue StandardError
        nil
      end

      # Best-effort: a gitignore hiccup (unwritable repo root, odd permission)
      # must never block isolation — the worktree still works, it just risks
      # showing up as untracked in `git status` at the repo root, a cosmetic
      # gap the user can fix by hand.
      def ensure_gitignore_entry!
        gitignore = File.join(@repo_root, ".gitignore")
        existing = File.exist?(gitignore) ? File.read(gitignore) : ""
        return if existing.lines.map(&:chomp).include?(GITIGNORE_ENTRY)

        File.open(gitignore, "a") do |f|
          f.write("\n") unless existing.empty? || existing.end_with?("\n")
          f.write("#{GITIGNORE_ENTRY}\n")
        end
      rescue StandardError
        nil
      end

      def redirect_workspace!
        @previous_cwd = Rubino.configuration.dig("terminal", "cwd")
        Rubino.configuration.set("terminal", "cwd", @path)
      end

      def inject_prompt_note!
        @previous_preamble = Rubino.configuration.prompts_preamble
        note = worktree_isolation_note
        combined = @previous_preamble ? "#{@previous_preamble}\n\n#{note}" : note
        Rubino.configuration.set("prompts", "preamble", combined)
      end

      # The model-facing note (#setup_workspace_and_trust!'s prompts.preamble
      # layer) telling the model it's in an isolated worktree and must commit
      # its work — never merge/push it — before the session ends.
      def worktree_isolation_note
        <<~TXT
          [Worktree isolation]
          You are working in an ISOLATED git worktree, not the user's checked-out
          branch: #{@path} (branch `#{@branch}`, branched from the repo's HEAD at
          the start of this session). This keeps your changes reviewable and
          discardable independent of the user's real working tree.
          - Commit your work here (`git add` + `git commit`) before the session
            ends, so there is something for the human to review.
          - Never merge, push, or open a pull request yourself — a human reviews
            and merges (or discards) this branch manually via normal git, after
            the session ends.
          - If nothing is committed, this worktree and branch are removed
            automatically when the session ends.
        TXT
      end

      def restore_config!
        Rubino.configuration.set("terminal", "cwd", @previous_cwd)
        Rubino.configuration.set("prompts", "preamble", @previous_preamble)
      end

      def commits_ahead
        out, status = Open3.capture2(
          "git", "rev-list", "--count", "#{@base_sha}..HEAD", chdir: @path, err: File::NULL
        )
        status.success? ? out.strip.to_i : 0
      rescue StandardError
        0
      end

      # Removes the linked worktree, then the branch — in that order, and the
      # branch delete is GATED on the worktree remove succeeding, so a failed
      # removal never orphans the branch (leaving it unreachable from the
      # worktree that was its only checkout). `--force` discards uncommitted/
      # untracked changes in the linked worktree (there are, by construction,
      # no COMMITS worth keeping when this is called from the discard path of
      # #cleanup! — see its doc). Best-effort: a removal failure just leaves
      # the worktree directory behind (an accepted cost, see the class doc),
      # never raises.
      def remove!
        _, status = Open3.capture2e("git", "worktree", "remove", "--force", @path, chdir: @repo_root)
        Open3.capture2e("git", "branch", "-D", @branch, chdir: @repo_root) if status.success?
      rescue StandardError
        nil
      end

      def kept_message(ahead)
        commit_word = ahead == 1 ? "commit" : "commits"
        "worktree kept for review: #{@path}\n  " \
          "branch #{@branch} — #{ahead} #{commit_word} ahead of the session's starting point\n  " \
          "review:  git -C #{@path} log #{@base_sha}..HEAD\n  " \
          "diff:    git -C #{@path} diff #{@base_sha}..HEAD\n  " \
          "merge (you decide): git checkout <target> && git merge #{@branch}\n  " \
          "discard: git worktree remove --force #{@path} && git branch -D #{@branch}"
      end
    end
  end
end
