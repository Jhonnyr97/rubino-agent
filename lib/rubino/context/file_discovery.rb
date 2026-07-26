# frozen_string_literal: true

module Rubino
  module Context
    # Discovers and loads project-instruction files from the working directory.
    #
    # Mirrors Hermes's precedence chain (prompt_builder.py:1482-1523):
    #   FIRST MATCH WINS — only ONE project-context type is loaded.
    #   1. .rubino.md / RUBINO.md  (walk up to git root)
    #   2. AGENTS.md / agents.md   (cwd only)
    #   3. CLAUDE.md / claude.md   (cwd only)
    #   4. .cursorrules / .cursor/rules/*.mdc  (cwd only)
    #
    # Each source is capped at 20,000 chars (head 70% + tail 20% truncation).
    # YAML frontmatter is stripped only from the rubino-own file
    # (.rubino.md / RUBINO.md), matching Hermes's .hermes.md / HERMES.md
    # treatment.  Content is scanned for prompt injection via
    # Security::ContentScanner before injection, mirroring Hermes's
    # _scan_context_content (prompt_builder.py:45).
    class FileDiscovery
      CONTEXT_FILE_MAX_CHARS = 20_000
      TRUNCATE_HEAD_RATIO = 0.7
      TRUNCATE_TAIL_RATIO = 0.2

      RUBINO_FILE_NAMES = %w[.rubino.md RUBINO.md].freeze
      AGENTS_FILE_NAMES = %w[AGENTS.md agents.md].freeze
      CLAUDE_FILE_NAMES = %w[CLAUDE.md claude.md].freeze

      def initialize(base_path: nil)
        @base_path = File.expand_path(base_path || Dir.pwd)
      end

      # Returns a hash with :filename and :content keys representing the single
      # loaded project-context file, or nil when no file was found or loading
      # failed.  Callers format this into the system prompt with the appropriate
      # header — the discovery class does not do formatting.
      def load_project_context
        load_rubino_md || load_agents_md || load_claude_md || load_cursorrules
      rescue StandardError
        nil
      end

      # Cheap existence probe for TrustGate.gateworthy? — does this dir ship
      # ANY project-context file across the same precedence tiers as
      # +load_project_context+, without paying for reading/scanning/
      # truncating content (and without the security-scan side effect).
      # Callers only need a boolean "is there something to gate here", not
      # the file itself.
      def context_file?
        !!(find_rubino_md ||
           find_one_in_cwd(AGENTS_FILE_NAMES) ||
           find_one_in_cwd(CLAUDE_FILE_NAMES) ||
           cursorrules_present?)
      rescue StandardError
        false
      end

      private

      # Existence-only counterpart to load_cursorrules: true when either
      # .cursorrules or at least one .cursor/rules/*.mdc file is present.
      def cursorrules_present?
        return true if File.exist?(File.join(@base_path, ".cursorrules"))

        !Dir.glob(File.join(@base_path, ".cursor", "rules", "*.mdc")).empty?
      end

      # -- tier 1: .rubino.md / RUBINO.md (walk up to git root) ------------

      def load_rubino_md
        path = find_rubino_md
        return nil unless path

        content = read_and_check(path)
        return nil unless content

        content = strip_yaml_frontmatter(content)
        content = Security::ContentScanner.scan(content, source: File.basename(path))
        content = truncate_content(content, File.basename(path))
        { filename: File.basename(path), content: content }
      end

      def find_rubino_md
        stop_at = git_root(@base_path)
        current = Pathname.new(@base_path).realpath

        loop do
          RUBINO_FILE_NAMES.each do |name|
            candidate = current.join(name)
            return candidate.to_s if candidate.file?
          end
          break if stop_at && current.to_s == stop_at

          parent = current.parent
          break if parent == current # filesystem root

          current = parent
        end
        nil
      end

      # -- tier 2: AGENTS.md / agents.md (cwd only) -----------------------

      def load_agents_md
        path = find_one_in_cwd(AGENTS_FILE_NAMES)
        return nil unless path

        content = read_and_check(path)
        return nil unless content

        content = Security::ContentScanner.scan(content, source: File.basename(path))
        content = truncate_content(content, File.basename(path))
        filename = File.basename(path)
        { filename: filename, content: content }
      end

      # -- tier 3: CLAUDE.md / claude.md (cwd only) -----------------------

      def load_claude_md
        path = find_one_in_cwd(CLAUDE_FILE_NAMES)
        return nil unless path

        content = read_and_check(path)
        return nil unless content

        content = Security::ContentScanner.scan(content, source: File.basename(path))
        content = truncate_content(content, File.basename(path))
        filename = File.basename(path)
        { filename: filename, content: content }
      end

      # -- tier 4: .cursorrules + .cursor/rules/*.mdc (cwd only) ----------

      def load_cursorrules
        parts = []

        cursorrules_file = File.join(@base_path, ".cursorrules")
        if File.exist?(cursorrules_file)
          content = read_and_check(cursorrules_file)
          parts << "## .cursorrules\n\n#{content}" if content
        end

        cursor_rules_dir = File.join(@base_path, ".cursor", "rules")
        if File.directory?(cursor_rules_dir)
          Dir.glob(File.join(cursor_rules_dir, "*.mdc")).each do |mdc_file|
            content = read_and_check(mdc_file)
            if content
              rel = ".cursor/rules/#{File.basename(mdc_file)}"
              parts << "## #{rel}\n\n#{content}"
            end
          end
        end

        return nil if parts.empty?

        combined = parts.join("\n\n")
        combined = Security::ContentScanner.scan(combined, source: ".cursorrules")
        combined = truncate_content(combined, ".cursorrules")
        { filename: ".cursorrules", content: combined }
      end

      # -- helpers --------------------------------------------------------

      def read_and_check(path)
        content = File.read(path, encoding: "UTF-8").strip
        content.empty? ? nil : content
      rescue StandardError
        nil
      end

      # Walk up looking for a .git directory (pure-Path, no shell-out).
      # Returns the path string of the git root, or nil if not in a repo.
      def git_root(start_path)
        current = Pathname.new(start_path).realpath
        loop do
          return current.to_s if current.join(".git").exist?

          parent = current.parent
          break if parent == current # filesystem root

          current = parent
        end
        nil
      end

      # Find the first existing file from +names+ in @base_path.
      def find_one_in_cwd(names)
        names.each do |name|
          path = File.join(@base_path, name)
          return path if File.exist?(path)
        end
        nil
      end

      # Strip YAML frontmatter (--- delimited). Only applied to the
      # rubino-own file, matching Hermes's _strip_yaml_frontmatter behaviour
      # for .hermes.md / HERMES.md.
      def strip_yaml_frontmatter(content)
        return content unless content.start_with?("---")

        close = content.index("\n---", 3)
        return content unless close

        body = content[(close + 4)..]
        body = body.lstrip
        body.empty? ? content : body
      end

      # Head/tail truncation with a marker. Mirrors Hermes's _truncate_content.
      def truncate_content(content, filename)
        return content if content.length <= CONTEXT_FILE_MAX_CHARS

        head_chars = (CONTEXT_FILE_MAX_CHARS * TRUNCATE_HEAD_RATIO).to_i
        tail_chars = (CONTEXT_FILE_MAX_CHARS * TRUNCATE_TAIL_RATIO).to_i
        head = content[0, head_chars]
        tail = content[-tail_chars..]
        marker = "\n\n[...truncated #{filename}: " \
                 "kept #{head_chars}+#{tail_chars} of #{content.length} chars. " \
                 "Use file tools to read the full file.]\n\n"
        "#{head}#{marker}#{tail}"
      end
    end
  end
end
