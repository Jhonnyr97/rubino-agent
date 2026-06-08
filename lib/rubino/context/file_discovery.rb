# frozen_string_literal: true

module Rubino
  module Context
    # Discovers and loads project context files from the working directory.
    # Supports multiple file conventions (.rubino.md, AGENTS.md, etc.)
    class FileDiscovery
      CONTEXT_FILES = %w[
        .rubino.md
        RUBINO.md
        AGENTS.md
        CLAUDE.md
        .cursorrules
      ].freeze

      def initialize(base_path: nil)
        @base_path = base_path || Dir.pwd
      end

      # Loads and concatenates all found project context files
      def load_project_context
        files = discover_files
        return nil if files.empty?

        files.map { |f| File.read(f) }.join("\n\n---\n\n")
      end

      # Returns list of discovered context file paths
      def discover_files
        CONTEXT_FILES.filter_map do |filename|
          path = File.join(@base_path, filename)
          path if File.exist?(path)
        end
      end

      # Checks a subdirectory for local context files
      def local_context(subdir)
        CONTEXT_FILES.filter_map do |filename|
          path = File.join(@base_path, subdir, filename)
          File.read(path) if File.exist?(path)
        end.join("\n")
      end
    end
  end
end
