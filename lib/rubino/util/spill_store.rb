# frozen_string_literal: true

require "fileutils"

module Rubino
  module Util
    # Lifecycle for the on-disk "spill" artifacts rubino writes outside the
    # database (#374):
    #
    #   * tool-result spills — <home>/tool-results/<call_id>.txt, the full
    #     pre-truncation output the model can `read` back (ToolExecutor).
    #   * oversized pastes    — <home>/sessions/<id>/paste_N.txt, a big paste
    #     the model reads instead of inlining (UI::PasteStore).
    #
    # Both were write-only: nothing ever deleted them. A long-running session or
    # a CI box that runs thousands of large-output tools accumulated these files
    # FOREVER, and destroying a session (CleanupSessionsJob / Repository#destroy!)
    # only deleted DB rows, leaving the files orphaned. This module:
    #
    #   1. deletes a single session's spill+paste files when it is destroyed
    #      (#destroy_session_files), and
    #   2. evicts spill/paste files past an age and/or total-size budget
    #      (#evict!), called opportunistically and from CleanupSessionsJob.
    #
    # All methods are best-effort: an IO error must never take down the agent.
    module SpillStore
      # Default eviction policy. Tunable via the cleanup config, but these are
      # the safe built-ins: drop anything older than the retention window, and
      # keep the combined on-disk footprint of spills+pastes under the budget by
      # evicting oldest-first.
      DEFAULT_MAX_AGE_SECONDS = 7 * 86_400        # 7 days
      DEFAULT_MAX_TOTAL_BYTES = 512 * 1024 * 1024 # 512 MB

      module_function

      # The directory holding per-call tool-result spills.
      def tool_results_dir
        File.join(Rubino.home_path, "tool-results")
      end

      # The directory holding all per-session subtrees (each session's pastes
      # live in <sessions>/<id>/paste_N.txt).
      def sessions_dir
        File.join(Rubino.home_path, "sessions")
      end

      # Removes the on-disk spill + paste artifacts owned by +session_id+ when
      # the session is destroyed (#374). Pastes are session-scoped so the whole
      # <sessions>/<id> subtree goes; tool-result spills are keyed by call_id, so
      # the caller passes the session's call_ids (looked up before the DB rows
      # are deleted) and we remove the matching <tool-results>/<call_id>.txt.
      # Best-effort; returns nil.
      def destroy_session_files(session_id, call_ids: [])
        return if session_id.nil? || session_id.to_s.empty?

        FileUtils.rm_rf(File.join(sessions_dir, session_id.to_s))
        Array(call_ids).each do |cid|
          safe = sanitize_call_id(cid)
          next if safe.nil?

          FileUtils.rm_f(File.join(tool_results_dir, "#{safe}.txt"))
        end
        nil
      rescue StandardError => e
        Rubino.logger&.warn(event: "spill_store.destroy_failed", error: e.message)
        nil
      end

      # Evicts spill + paste files past the age and/or total-size budget. Age
      # first (drop everything older than max_age), then size (if the survivors
      # still exceed max_total_bytes, delete oldest-first until under budget).
      # Empty per-session paste dirs left behind are pruned. Best-effort;
      # returns the number of files deleted.
      def evict!(max_age_seconds: DEFAULT_MAX_AGE_SECONDS, max_total_bytes: DEFAULT_MAX_TOTAL_BYTES,
                 now: Time.now)
        files   = collect_files
        deleted = 0

        if max_age_seconds && max_age_seconds.positive?
          cutoff = now - max_age_seconds
          files.reject! do |f|
            next false unless f[:mtime] < cutoff

            FileUtils.rm_f(f[:path])
            deleted += 1
            true
          end
        end

        if max_total_bytes && max_total_bytes.positive?
          total = files.sum { |f| f[:size] }
          if total > max_total_bytes
            # Oldest first until back under budget.
            files.sort_by! { |f| f[:mtime] }
            files.each do |f|
              break if total <= max_total_bytes

              FileUtils.rm_f(f[:path])
              total   -= f[:size]
              deleted += 1
            end
          end
        end

        prune_empty_session_dirs
        deleted
      rescue StandardError => e
        Rubino.logger&.warn(event: "spill_store.evict_failed", error: e.message)
        deleted
      end

      # All spill + paste files as {path:, size:, mtime:} records.
      def collect_files
        out = []
        out.concat(stat_glob(File.join(tool_results_dir, "*.txt")))
        out.concat(stat_glob(File.join(sessions_dir, "*", "paste_*.txt")))
        out
      end

      def stat_glob(pattern)
        Dir.glob(pattern).filter_map do |path|
          stat = File.stat(path)
          next unless stat.file?

          { path: path, size: stat.size, mtime: stat.mtime }
        rescue StandardError
          nil
        end
      end

      # Removes now-empty per-session paste dirs (a session whose only files
      # were pastes that got evicted) so the sessions tree doesn't fill with
      # empty directories. Never touches a dir that still has contents.
      def prune_empty_session_dirs
        Dir.glob(File.join(sessions_dir, "*")).each do |dir|
          next unless File.directory?(dir)
          next unless (Dir.entries(dir) - %w[. ..]).empty?

          Dir.rmdir(dir)
        rescue StandardError
          nil
        end
      end

      # Mirrors ToolExecutor#spill_full_output's filename sanitization so the
      # path we delete matches the path that was written.
      def sanitize_call_id(call_id)
        id = call_id.to_s.gsub(/[^a-zA-Z0-9_.-]/, "_")
        id.empty? ? nil : id
      end
    end
  end
end
