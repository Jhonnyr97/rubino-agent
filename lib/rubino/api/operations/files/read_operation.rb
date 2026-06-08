# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Files
        # GET /v1/files?path=relative/path
        # Streams raw bytes from a path inside the sandboxed workspace as
        # application/octet-stream. Path traversal is enforced by the workspace.
        #
        # @return [[Integer, Hash, Array<String>]] 200 + octet-stream Rack triple.
        # @raise [Rubino::ValidationError] when the +path+ query parameter is missing or empty.
        class ReadOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate workspace for tests.
          #
          # Roots the workspace at the SAME directory the tools sandbox to
          # (terminal.cwd || Dir.pwd), not config.paths_home. Tools and
          # attach_file emit absolute paths under that root, so a produced
          # artifact lives there — rooting at paths_home would make every
          # such path look like a traversal escape and 422 the download.
          def initialize(workspace: nil)
            @workspace = workspace || ::Rubino::Files::Workspace.new(root: ::Rubino::Tools::Base.workspace_root)
          end

          def call(request)
            path = request.query["path"]
            raise ValidationError, "path query parameter is required" if path.nil? || path.empty?

            content = @workspace.read(path)
            [200, { "content-type" => "application/octet-stream" }, [content]]
          end
        end
      end
    end
  end
end
