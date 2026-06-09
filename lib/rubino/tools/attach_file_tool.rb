# frozen_string_literal: true

require "pathname"

module Rubino
  module Tools
    # Hands a previously-written file to the surrounding UI as a downloadable
    # artifact. The tool itself does not move bytes — it validates the path
    # against the workspace and the file's existence, then surfaces a
    # structured artifact payload that the agent loop turns into an
    # ARTIFACT_CREATED event. Downstream consumers (the web UI's
    # run job, the CLI) fetch the file separately via GET /v1/files.
    #
    # Why a dedicated tool rather than inferring artifacts from write/edit
    # tool calls: the model writes lots of intermediate files (helper
    # scripts, scratch JSON, downloaded fixtures) that should NOT show up
    # as user-facing downloads. An explicit attach_file call makes that
    # decision intentional and reviewable.
    class AttachFileTool < Base
      DEFAULT_CONTENT_TYPE = "application/octet-stream"

      # Minimal extension → MIME map. Anything not listed falls back to
      # application/octet-stream; the browser will then decide based on
      # filename. Add entries here only when a real run needs a specific
      # type signalled (e.g. inline PDF preview).
      CONTENT_TYPES = {
        "pdf" => "application/pdf",
        "csv" => "text/csv",
        "txt" => "text/plain",
        "md" => "text/markdown",
        "json" => "application/json",
        "html" => "text/html",
        "htm" => "text/html",
        "xml" => "application/xml",
        "png" => "image/png",
        "jpg" => "image/jpeg",
        "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "svg" => "image/svg+xml",
        "zip" => "application/zip",
        "tar" => "application/x-tar",
        "gz" => "application/gzip",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      }.freeze

      def name
        "attach_file"
      end

      def description
        "Attach a previously-written file to the current turn as a downloadable artifact " \
          "for the user. Call this AFTER you have already created the file with write/edit/shell. " \
          "Pass the absolute or workspace-relative path. The tool does not copy or move the file — " \
          "it just registers it as a deliverable. Use for final user-facing outputs " \
          "(PDF, CSV, ZIP, reports) and not for intermediate helper scripts."
      end

      def input_schema
        {
          type: "object",
          properties: {
            file_path: {
              type: "string",
              description: "Path to the file to attach. Must exist and live inside the workspace."
            },
            filename: {
              type: "string",
              description: "Optional display name; defaults to the basename of file_path."
            }
          },
          required: %w[file_path]
        }
      end

      def risk_level
        :low
      end

      def call(arguments)
        file_path = (arguments["file_path"] || arguments[:file_path]).to_s
        return error("file_path is required") if file_path.empty?

        expanded = File.expand_path(file_path)
        return error("File not found: #{file_path}") unless File.exist?(expanded)
        return error("Not a regular file: #{file_path}") unless File.file?(expanded)
        return error("Path escapes the workspace: #{file_path}") unless within_workspace?(expanded)

        display = (arguments["filename"] || arguments[:filename]).to_s
        display = File.basename(expanded) if display.empty?

        size = File.size(expanded)
        artifact = {
          path: expanded,
          filename: display,
          content_type: content_type_for(expanded),
          byte_size: size
        }

        {
          output: "Attached #{display} (#{size} bytes) as a downloadable artifact.",
          metrics: "#{size} bytes",
          artifact: artifact
        }
      end

      private

      def error(message)
        { output: "Error: #{message}", error_code: :attach_failed }
      end

      def content_type_for(path)
        ext = File.extname(path).to_s.sub(/\A\./, "").downcase
        CONTENT_TYPES[ext] || DEFAULT_CONTENT_TYPE
      end
    end
  end
end
