# frozen_string_literal: true

require "pathname"
require "fileutils"
require "securerandom"

module Rubino
  module Files
    # Sandboxed filesystem access for the agent. Every path coming in from
    # the HTTP API (read, upload, etc.) must be resolved through #resolve so
    # the result is guaranteed to live under @root.
    #
    # Root defaults to config.paths_home (the agent home); uploads are
    # written under `<root>/uploads/`. The root is overridable in tests.
    #
    # Path-traversal defense:
    # - Pathname#+ does not normalize: `Pathname.new("/a") + "/b"` returns
    #   `/b`, so an attacker-supplied absolute path would silently escape.
    # - We therefore call #expand_path on the joined path and then verify it
    #   begins with `@root + File::SEPARATOR` (or equals @root). If not,
    #   we raise Workspace::PathTraversal (a ValidationError subclass).
    class Workspace
      class PathTraversal < ::Rubino::ValidationError
        def initialize(path)
          super("path escapes workspace: #{path}")
        end
      end

      def initialize(root: nil)
        path = root || ::Rubino.configuration.paths_home
        expanded = File.expand_path(path)
        FileUtils.mkdir_p(expanded)
        # Resolve symlinks (macOS' /tmp → /private/tmp is the usual offender)
        # so #resolve compares apples to apples. Tools and AttachFileTool
        # both call File.expand_path on their inputs, which follows OS
        # symlinks; storing the raw configured root here would then make
        # every absolute path under /tmp look like an escape, even though
        # it really points inside the sandbox.
        @root = Pathname.new(File.realpath(expanded))
      end

      attr_reader :root

      # Resolves a relative path against the workspace root.
      # Raises PathTraversal if the resolved path escapes the root.
      def resolve(relative_path)
        candidate = (@root + relative_path).expand_path
        # If the candidate exists on disk, run it through realpath too so
        # symlink components in the leading path don't make us reject a
        # path that physically lives under @root. For paths that don't
        # exist yet (the upload-create case) we keep the expand_path form
        # — File.realpath would raise on a missing file.
        candidate = Pathname.new(File.realpath(candidate.to_s)) if candidate.exist?

        unless candidate.to_s.start_with?(@root.to_s + File::SEPARATOR) || candidate == @root
          raise PathTraversal, relative_path
        end

        candidate
      end

      # Reads a file from the sandbox.
      #
      # @param relative_path [String] path relative to the workspace root
      # @return [String] binary contents of the file
      # @raise [Workspace::PathTraversal] if the path escapes the sandbox
      # @raise [Rubino::NotFoundError] if no regular file exists at the path
      def read(relative_path)
        path = resolve(relative_path)
        raise ::Rubino::NotFoundError.new("file", relative_path) unless path.file?

        path.binread
      end

      # Stores an uploaded file under `uploads/<uuid>-<basename>`.
      # The original filename is reduced to its basename before joining, so
      # callers cannot influence the destination directory.
      #
      # @param filename [String] client-supplied name (basename only is kept)
      # @param io [IO] readable stream containing the upload body
      # @return [Hash] descriptor with keys :id, :filename, :size, :path
      def upload(filename:, io:)
        uploads_dir = @root + "uploads"
        FileUtils.mkdir_p(uploads_dir)
        safe_name = File.basename(filename.to_s)
        id = SecureRandom.uuid
        target = uploads_dir + "#{id}-#{safe_name}"
        size = IO.copy_stream(io, target.to_s)
        { id: id, filename: safe_name, size: size, path: target.to_s }
      end
    end
  end
end
