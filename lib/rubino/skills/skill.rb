# frozen_string_literal: true

require "yaml"

module Rubino
  module Skills
    # Represents a single skill. Two layouts are supported:
    #   * flat file  — <dir>/<name>.md (the skill name is the basename)
    #   * directory  — <dir>/<name>/SKILL.md (the skill name is the dir name,
    #     plus bundled files under references/ scripts/ assets/ etc.)
    #
    # In both cases `path` points at the markdown body that carries the
    # name/description frontmatter. Directory skills also expose `linked_files`
    # (relative paths of bundled files) and can read a specific bundled file
    # sandboxed to the skill's own directory.
    class Skill
      attr_reader :name, :description, :path, :metadata, :linked_files

      def initialize(path:)
        @path = path
        @metadata = {}
        @content = nil
        @linked_files = []
        @directory = directory_skill? ? File.dirname(path) : nil
        discover_linked_files! if directory?
        parse_frontmatter!
      end

      # True when this skill is backed by a <name>/SKILL.md directory.
      def directory?
        !@directory.nil?
      end

      # The skill's own directory (only for directory skills).
      def dir
        @directory
      end

      # Returns the full skill content (loaded lazily)
      def content
        @content ||= load_content
      end

      # Returns true if the skill has been fully loaded
      def loaded?
        !@content.nil?
      end

      # Reads a bundled file by its relative path, sandboxed to the skill dir.
      # Returns the file contents, or nil if the skill has no directory, the
      # path escapes the skill dir, or the file does not exist.
      #
      # Resolve and read happen back-to-back with no listing step in between, so
      # the caller can't observe a "present in the listing but unreadable" state
      # from THIS method. A File::ENOENT between #file? and #read (the skill dir
      # being torn down mid-call) is swallowed to nil rather than raised, so a
      # concurrent teardown reads as a clean miss instead of a crash (W3).
      def read_file(relative_path)
        return nil unless directory?

        resolved = resolve_within_dir(relative_path)
        return nil unless resolved && File.file?(resolved)

        File.read(resolved, encoding: "UTF-8")
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      # Live relative paths of bundled files, recomputed from disk. Unlike the
      # +linked_files+ snapshot taken at init, this reflects the current dir
      # state — so an error message built from it can't list a file that
      # #read_file just failed to find (the W3 self-contradiction). Empty for
      # flat-file skills.
      def current_linked_files
        return [] unless directory?

        collect_linked_files
      end

      # Returns a summary for the agent to see available skills
      def summary
        "#{@name}: #{@description}"
      end

      private

      def directory_skill?
        File.basename(@path) == "SKILL.md"
      end

      # Caches the init-time snapshot in +@linked_files+ (the system-prompt
      # hint shows this). The live recompute path uses #collect_linked_files
      # directly so the two never drift in logic.
      def discover_linked_files!
        @linked_files = collect_linked_files
      end

      # Relative paths of bundled files under the skill dir, excluding SKILL.md
      # itself and vcs/junk dirs. Sorted for deterministic output. Re-globs the
      # directory on every call, so it reflects current disk state.
      def collect_linked_files
        files = Dir.glob(File.join(@directory, "**", "*"), File::FNM_DOTMATCH).filter_map do |entry|
          next unless File.file?(entry)

          rel = entry.delete_prefix("#{@directory}#{File::SEPARATOR}")
          next if rel == "SKILL.md"
          next if rel.split(File::SEPARATOR).any? { |seg| EXCLUDED_DIRS.include?(seg) }

          rel
        end
        files.sort
      end

      # Resolves a relative path against the skill dir and rejects anything that
      # escapes it (via .., absolute paths, or symlinks pointing outside).
      def resolve_within_dir(relative_path)
        return nil if relative_path.nil? || relative_path.to_s.empty?

        root = File.realpath(@directory)
        target = File.expand_path(relative_path.to_s, root)
        candidate = File.exist?(target) ? File.realpath(target) : target

        return nil unless candidate == root || candidate.start_with?("#{root}#{File::SEPARATOR}")

        candidate
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        nil
      end

      # Reads the markdown body as UTF-8, replacing any invalid/undefined byte
      # sequences instead of raising. A single skill carrying a non-UTF-8
      # SKILL.md (a corrupt or hostile file) must never crash discovery — it
      # used to raise ArgumentError("invalid byte sequence") deep inside
      # `raw.split("---")` and brick the whole registry (SKILL-2). Scrubbing
      # keeps the readable text and turns the bad bytes into U+FFFD.
      #
      # The entrypoint itself is confined and size-capped (R2-M3) BEFORE it is
      # read: see #safe_source_path (refuses a SKILL.md that symlinks OUT of its
      # skill dir, e.g. -> /etc/passwd) and #cap_source (truncates a SKILL.md
      # past MAX_SOURCE_BYTES so a multi-MB body can't flood the system prompt).
      def read_source
        cap_source(File.read(safe_source_path, encoding: "UTF-8"))
          .scrub("�")
      end

      # The entrypoint markdown path, resolved through symlinks and refused if it
      # escapes its own skill dir (R2-M3). The existing #resolve_within_dir
      # confines BUNDLED files read via #read_file, but the SKILL.md/<name>.md
      # ENTRYPOINT was read straight off @path — a hostile catalogue could make
      # it a symlink to /etc/passwd and have its contents mined into the skill
      # summary (every prompt) and body. Raising here makes Registry#add_skills
      # skip the skill with a warning instead of following the link.
      def safe_source_path
        root = File.realpath(File.dirname(@path))
        resolved = File.realpath(@path)
        unless resolved == File.join(root, File.basename(@path)) ||
               resolved.start_with?("#{root}#{File::SEPARATOR}")
          raise Rubino::Error, "skill entrypoint escapes its directory: #{@path}"
        end

        resolved
      end

      # Truncate an over-budget SKILL.md so a giant (e.g. 5 MB) body can't load
      # uncapped into the prompt (R2-M3). Keeps the leading MAX_SOURCE_BYTES,
      # which still carries the frontmatter + the start of the body, and appends a
      # visible marker. byteslice can split a multibyte char; #read_source scrubs
      # the dangling bytes to U+FFFD right after.
      def cap_source(raw)
        return raw if raw.bytesize <= MAX_SOURCE_BYTES

        "#{raw.byteslice(0, MAX_SOURCE_BYTES)}\n\n[skill truncated: exceeded #{MAX_SOURCE_BYTES} bytes]"
      end

      def parse_frontmatter!
        raw = read_source

        if raw.start_with?("---")
          parts = raw.split("---", 3)
          if parts.size >= 3
            begin
              @metadata = YAML.safe_load(parts[1], permitted_classes: [Symbol]) || {}
            rescue Psych::SyntaxError => e
              warn "rubino: skipping malformed frontmatter in #{@path} " \
                   "(line #{e.line}: #{e.problem})"
              @metadata = {}
            end
            @metadata = {} unless @metadata.is_a?(Hash)
            @name = (@metadata["name"] || default_name).to_s
            @description = @metadata["description"] || ""
          else
            @name = default_name
            @description = ""
          end
        else
          @name = default_name
          @description = raw.lines.first&.strip&.sub(/^#\s*/, "") || ""
        end
      end

      # For a directory skill the name is the directory name; for a flat file
      # it is the markdown basename.
      def default_name
        directory? ? File.basename(@directory) : File.basename(@path, ".md")
      end

      def load_content
        raw = read_source

        if raw.start_with?("---")
          parts = raw.split("---", 3)
          parts.size >= 3 ? parts[2].strip : raw
        else
          raw
        end
      end

      EXCLUDED_DIRS = %w[.git .svn .hg node_modules __pycache__ .DS_Store].freeze

      # Hard cap on the SKILL.md entrypoint size read into memory/prompt (R2-M3).
      # A sane SKILL.md is a few KB of frontmatter + instructions; 256 KiB is
      # generous headroom while still refusing a multi-MB body that would flood
      # the system prompt. Past this the source is truncated (see #cap_source).
      MAX_SOURCE_BYTES = 256 * 1024
    end
  end
end
