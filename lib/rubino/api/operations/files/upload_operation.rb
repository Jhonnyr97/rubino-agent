# frozen_string_literal: true

require "rack/multipart"

module Rubino
  module API
    module Operations
      module Files
        # POST /v1/files (multipart/form-data, field "file")
        # Persists a single uploaded file into the sandboxed workspace and
        # returns its descriptor (id, filename, size).
        #
        # Multipart payload is capped at api.max_upload_bytes (default 50 MiB).
        # The cap is enforced twice: first against the declared Content-Length
        # (cheap reject before any IO), then by wrapping rack.input so a body
        # that lies about its size — or omits Content-Length entirely — still
        # aborts mid-stream before Rack::Multipart can fully buffer it to disk.
        #
        # @return [[Integer, Hash]] 201 + descriptor payload.
        # @raise [Rubino::ValidationError] when the content-type is not multipart or the "file" field is missing.
        # @raise [Rubino::PayloadTooLargeError] when the body exceeds the cap.
        class UploadOperation
          DEFAULT_MAX_UPLOAD_BYTES = 50 * 1024 * 1024

          # Wraps a Rack input stream and raises PayloadTooLargeError once the
          # cumulative bytes read pass +limit+. Rack::Multipart drives the read
          # loop, so raising here unwinds straight out of parse_multipart and
          # the partially-written tempfile is collected by the ensure block
          # in #call.
          class CappedInput
            def initialize(io, limit)
              @io = io
              @limit = limit
              @read = 0
            end

            def read(length = nil, buffer = nil)
              chunk = buffer ? @io.read(length, buffer) : @io.read(length)
              return chunk if chunk.nil?

              @read += chunk.bytesize
              raise Rubino::PayloadTooLargeError.new(
                "multipart upload exceeds #{@limit} bytes",
                details: { limit_bytes: @limit }
              ) if @read > @limit

              chunk
            end

            # Rack::Multipart::Parser interrogates rewind/eof?/gets on the input;
            # delegate so the parser is unaware it's wrapped.
            def rewind
              @read = 0
              @io.rewind
            end

            def eof?
              @io.eof?
            end

            def gets(*args)
              line = @io.gets(*args)
              return line if line.nil?

              @read += line.bytesize
              raise Rubino::PayloadTooLargeError.new(
                "multipart upload exceeds #{@limit} bytes",
                details: { limit_bytes: @limit }
              ) if @read > @limit

              line
            end

            def respond_to_missing?(name, include_private = false)
              @io.respond_to?(name, include_private) || super
            end

            def method_missing(name, *args, &block)
              return @io.send(name, *args, &block) if @io.respond_to?(name)

              super
            end
          end

          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate workspace for tests.
          #
          # Roots at the tool workspace (terminal.cwd || Dir.pwd), the same
          # root tools and attach_file use, so uploaded files land where the
          # agent can read them back. See ReadOperation for the rationale.
          def initialize(workspace: nil)
            @workspace = workspace || ::Rubino::Files::Workspace.new(root: ::Rubino::Tools::Base.workspace_root)
          end

          def call(request)
            content_type = request.env["CONTENT_TYPE"].to_s
            raise ValidationError, "content-type must be multipart/form-data" unless content_type.start_with?("multipart/form-data")

            limit = max_upload_bytes
            declared = request.env["CONTENT_LENGTH"].to_s
            raise PayloadTooLargeError.new(
              "multipart upload exceeds #{limit} bytes",
              details: { limit_bytes: limit }
            ) if !declared.empty? && declared.to_i > limit

            params = parse_with_cap(request.env, limit)
            upload = params["file"]
            raise ValidationError, "missing 'file' field" if upload.nil? || !upload.is_a?(Hash)

            descriptor = @workspace.upload(filename: upload[:filename], io: upload[:tempfile])
            [201, { id: descriptor[:id], filename: descriptor[:filename], size: descriptor[:size] }]
          end

          private

          # Wraps rack.input with CappedInput so a mid-stream overflow raises
          # before Rack::Multipart fully drains the body. On overflow we also
          # unlink any tempfile the parser already created for the partial
          # part, so no orphan upload is left under /tmp.
          def parse_with_cap(env, limit)
            original = env["rack.input"]
            return Rack::Multipart.parse_multipart(env) || {} if original.nil?

            capped = CappedInput.new(original, limit)
            env["rack.input"] = capped
            begin
              Rack::Multipart.parse_multipart(env) || {}
            rescue PayloadTooLargeError
              cleanup_partial_tempfiles(env)
              raise
            ensure
              env["rack.input"] = original
            end
          end

          # Rack::Multipart streams each part to a Tempfile created via
          # Rack::Multipart::Parser::TEMPFILE_FACTORY. When we abort mid-read
          # those tempfiles remain on disk because the parser never returned
          # the descriptor to us. We do not have a handle to them either —
          # but rack.tempfiles (set by Rack::Multipart::Parser since 2.2) is
          # the canonical collection. Unlink everything in it.
          def cleanup_partial_tempfiles(env)
            tempfiles = env["rack.tempfiles"]
            return unless tempfiles.is_a?(Array)

            tempfiles.each do |tf|
              tf.close unless tf.closed?
              File.unlink(tf.path) if tf.respond_to?(:path) && tf.path && File.exist?(tf.path)
            rescue StandardError
              # Best-effort cleanup; we already failed the request.
            end
            tempfiles.clear
          end

          def max_upload_bytes
            value = Rubino.configuration.dig("api", "max_upload_bytes")
            value.is_a?(Integer) && value.positive? ? value : DEFAULT_MAX_UPLOAD_BYTES
          end
        end
      end
    end
  end
end
