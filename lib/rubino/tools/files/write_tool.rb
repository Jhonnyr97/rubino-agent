# frozen_string_literal: true

require "fileutils"

module Rubino
  module Tools
    # Writes content to a file, creating parent directories if needed.
    # Overwrites existing files (the LLM is expected to Read first when in
    # doubt). Kept intentionally narrow — no append mode, no partial writes;
    # those belong in `edit` / `multi_edit`.
    class WriteTool < Base
      class ToolSecurity < Tools::ToolSecurity
        def risk = :medium
        def require_overwrite_guard = true
      end

      class ToolPresentation < Tools::ToolPresentation
        def stream_params? = true
      end

      security     ToolSecurity
      presentation ToolPresentation
      redaction_profile :none
      summary :file_path, relative_to: :workspace

      description "Write content to a file, overwriting any existing content. " \
                  "Creates parent directories if they do not exist. " \
                  "Use `edit` or `multi_edit` to modify an existing file in place."

      param :file_path, desc: "Absolute or relative file path"
      param :content,   desc: "Full file content to write"

      def execute(file_path:, content: "")
        expanded = expand_workspace_path(file_path)
        # SECRET/credential writes (#446) are no longer HARD-refused here — they
        # are gated UPSTREAM by Security::ApprovalPolicy#decide (→ :ask): an
        # APPROVED write to your .env actually writes, a denied/headless one
        # never reaches #call. The workspace sandbox below is unchanged.
        return workspace_violation_message(file_path) unless writable_workspace?(expanded)

        existed = File.exist?(expanded)
        # Read-before-overwrite guard (r5 MF-2, Claude Code's rule): writing
        # over an EXISTING file requires that the model read it this session, so
        # a blind `write` can't silently clobber content the model never saw
        # (the near-data-loss path). NEW files skip the guard. No tracker
        # injected → no guard (single-tool unit tests / one-shot MCP).
        if existed && (guard = overwrite_guard_error(expanded, file_path))
          return guard
        end

        FileUtils.mkdir_p(File.dirname(expanded))
        # Crash-safe write: temp-in-same-dir + fsync + atomic rename, so a
        # SIGINT/SIGTERM/OOM-kill mid-write leaves the ORIGINAL file intact
        # rather than a torn/truncated one (HIGH-1). The bare File.write here
        # could be cut mid-flush, destroying the user's existing content.
        Util::AtomicFile.write_atomic(expanded, content)
        # Refresh-on-own-write so a later edit of this just-written file passes
        # the read-gate (r5 B2) and a re-read sees it as authoritative.
        @read_tracker&.note_write(expanded, content)

        verb  = existed ? "overwrote" : "created"
        bytes = content.to_s.bytesize
        lines = content.to_s.lines.size
        result = { output: "#{verb} #{file_path} (#{bytes} bytes)",
                   metrics: "#{lines} line#{"s" if lines != 1} · #{bytes}B",
                   body_kind: :plain }
        preview = content_preview(content)
        result[:body] = preview if preview
        result
      rescue StandardError => e
        "Error writing #{file_path}: #{e.message}"
      end

      # The first lines of what was just written, shown inside the tool box so
      # the user can SEE the file content (Claude Code / Codex do the same — a
      # blind `✓ N lines` is opaque). Trimmed to a preview; the full file is on
      # disk. nil for an empty write so no empty body box renders.
      MAX_PREVIEW_LINES = 16

      def content_preview(content)
        text = content.to_s
        return nil if text.empty?

        lines = text.lines.map(&:chomp)
        Util::Preview.truncate_lines!(lines, MAX_PREVIEW_LINES)
        lines.join("\n")
      end
    end
  end
end
