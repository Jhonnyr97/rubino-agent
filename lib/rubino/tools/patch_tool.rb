# frozen_string_literal: true

require "fileutils"

module Rubino
  module Tools
    # Tool for applying unified diff patches to files.
    class PatchTool < Base
      def name
        "apply_patch"
      end

      def description
        "Apply a unified diff patch to one or more files. " \
        "Accepts standard unified diff format (like output from 'git diff')."
      end

      def input_schema
        {
          type: "object",
          properties: {
            patch: {
              type: "string",
              description: "The unified diff patch content to apply"
            },
            base_path: {
              type: "string",
              description: "Base directory for relative paths in the patch (defaults to cwd)"
            }
          },
          required: %w[patch]
        }
      end

      def risk_level
        :medium
      end

      def call(arguments)
        patch     = arguments["patch"]     || arguments[:patch]
        base_path = arguments["base_path"] || arguments[:base_path] || Dir.pwd

        hunks = parse_patch(patch)
        return "No changes applied" if hunks.empty?

        # Pass 1: validate every hunk against current disk state and compute
        # the new content for each file in memory. NO disk writes here. If
        # any single hunk fails (missing file, context mismatch, workspace
        # escape) we abort the whole patch — partial application across
        # multiple files leaves the tree in a state neither the user nor
        # the agent can easily reason about, and reverting it requires
        # knowing the prior contents which we no longer have.
        pending, error = plan_operations(hunks, base_path)
        return error if error

        # Pass 2: execute. cancellation_requested? polled between operations
        # so a Ctrl+C lands cleanly — at most one application is in flight.
        apply_operations(pending)
      end

      private

      def plan_operations(hunks, base_path)
        pending = []

        hunks.each do |hunk|
          file_path = File.expand_path(hunk[:file], base_path)

          unless within_workspace?(file_path)
            return [nil, workspace_violation_message(hunk[:file]) +
                        " (no changes applied — apply_patch is two-phase)"]
          end

          if hunk[:new_file]
            pending << { kind:    :create,
                         path:    file_path,
                         display: hunk[:file],
                         content: hunk[:additions].join("\n") + "\n" }
          elsif hunk[:delete_file]
            pending << { kind:    :delete,
                         path:    file_path,
                         display: hunk[:file] }
          else
            unless File.exist?(file_path)
              return [nil, "Error: File not found: #{hunk[:file]} (no changes applied)"]
            end

            content                   = File.read(file_path)
            new_content, drift, fuzzy = apply_hunk(content, hunk)
            if new_content.nil?
              return [nil, "Error: Could not apply hunk to #{hunk[:file]} - " \
                           "context mismatch (no changes applied)"]
            end

            pending << { kind:    :patch,
                         path:    file_path,
                         display: hunk[:file],
                         content: new_content,
                         drift:   drift,
                         fuzzy:   fuzzy,
                         adds:    hunk[:additions].size,
                         dels:    hunk[:deletions].size }
          end
        end

        [pending, nil]
      end

      def apply_operations(pending)
        results = []

        pending.each do |op|
          if cancellation_requested?
            remaining = pending.size - results.size
            results << "[cancelled — #{remaining} operation(s) skipped]"
            break
          end

          case op[:kind]
          when :create
            FileUtils.mkdir_p(File.dirname(op[:path]))
            File.write(op[:path], op[:content])
            results << "Created: #{op[:display]}"
          when :delete
            File.delete(op[:path]) if File.exist?(op[:path])
            results << "Deleted: #{op[:display]}"
          when :patch
            File.write(op[:path], op[:content])
            results << patch_result_line(op)
          end
        end

        results.join("\n")
      end

      # The drift note is the bit that distinguishes "applied exactly where
      # the diff said" from "found by fuzzy search ±20 lines away". The old
      # tool silently let the fuzzy case through and reported success — if
      # the model was off by 50 lines we'd write to the wrong place and
      # claim it worked.
      def patch_result_line(op)
        base = "Patched: #{op[:display]} (#{op[:adds]} additions, #{op[:dels]} deletions)"
        return base unless op[:fuzzy]

        offset = op[:drift]
        signed = "#{offset.positive? ? '+' : ''}#{offset}"
        "#{base} [fuzzy match: applied #{signed} line(s) from requested position]"
      end

      def parse_patch(patch)
        hunks        = []
        current_file = nil
        # Flags carried at the file level — set before any @@ hunk header
        pending_new_file    = false
        pending_delete_file = false

        patch.each_line do |line|
          case line
          when /^--- \/dev\/null/
            # New file: source is /dev/null
            pending_new_file = true
          when /^--- a\/(.*)/
            # Normal source file — set current_file and reset pending flags
            current_file        = Regexp.last_match(1).strip
            pending_new_file    = false
            pending_delete_file = false
          when /^\+\+\+ \/dev\/null/
            # Delete file: destination is /dev/null; current_file already set by --- a/
            pending_delete_file = true
          when /^\+\+\+ b\/(.*)/
            current_file = Regexp.last_match(1).strip
          when /^@@ -(\d+),?\d* \+(\d+),?\d* @@/
            hunk = {
              file:        current_file,
              start_line:  Regexp.last_match(1).to_i,
              new_start:   Regexp.last_match(2).to_i,
              context:     [],
              additions:   [],
              deletions:   [],
              lines:       [],
              new_file:    pending_new_file,
              delete_file: pending_delete_file
            }
            hunks << hunk
            # Reset pending flags after consuming them
            pending_new_file    = false
            pending_delete_file = false
          else
            hunk = hunks.last
            next unless hunk

            if line.start_with?("+")
              hunk[:additions] << line[1..].rstrip
              hunk[:lines]     << { type: :add, content: line[1..].rstrip }
            elsif line.start_with?("-")
              hunk[:deletions] << line[1..].rstrip
              hunk[:lines]     << { type: :del, content: line[1..].rstrip }
            elsif line.start_with?(" ")
              hunk[:context] << line[1..].rstrip
              hunk[:lines]   << { type: :ctx, content: line[1..].rstrip }
            end
          end
        end

        hunks
      end

      # Returns [new_content, drift, fuzzy].
      #   new_content: the rewritten file content, or nil if context can't
      #                be found anywhere within the fuzzy search window.
      #   drift:       signed line offset from the hunk's requested start
      #                (0 = exact match).
      #   fuzzy:       true iff the match was found by find_context rather
      #                than at the requested line. The caller surfaces this
      #                so the model can see "I asked line 10, you applied
      #                at line 13" instead of trusting a silent fuzzy match.
      def apply_hunk(content, hunk)
        lines        = content.lines.map(&:rstrip)
        requested_ix = hunk[:start_line] - 1
        start_idx    = requested_ix
        fuzzy        = false

        expected = hunk[:lines].reject { |l| l[:type] == :add }.map { |l| l[:content] }

        actual = lines[start_idx, expected.size]
        unless actual && actual.map(&:rstrip) == expected.map(&:rstrip)
          found_idx = find_context(lines, expected, start_idx)
          return [nil, 0, false] unless found_idx

          start_idx = found_idx
          fuzzy     = (found_idx != requested_ix)
        end

        new_lines = lines[0...start_idx]
        hunk[:lines].each do |line|
          case line[:type]
          when :add, :ctx
            new_lines << line[:content]
          when :del
            # removed — skip
          end
        end
        new_lines.concat(lines[(start_idx + expected.size)..] || [])

        [new_lines.join("\n") + "\n", start_idx - requested_ix, fuzzy]
      end

      def find_context(lines, expected, hint_idx)
        search_range = 20
        start  = [0, hint_idx - search_range].max
        finish = [lines.size - expected.size, hint_idx + search_range].min

        (start..finish).each do |idx|
          actual = lines[idx, expected.size]
          return idx if actual && actual.map(&:rstrip) == expected.map(&:rstrip)
        end

        nil
      end
    end
  end
end
