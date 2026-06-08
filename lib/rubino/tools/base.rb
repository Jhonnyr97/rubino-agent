# frozen_string_literal: true

module Rubino
  module Tools
    # Abstract base class for all tools.
    # Each tool must implement: name, description, input_schema, risk_level, call.
    class Base
      # Set by ToolExecutor before each call so long-running tools (shell,
      # http, watchers) can poll for user cancellation. Default is nil — the
      # tool should treat that as "no cancellation possible" and not crash.
      attr_accessor :cancel_token

      # Per-turn ReadTracker injected by ToolExecutor. ReadTool registers
      # successful reads; EditTool / MultiEditTool consult it before writing
      # so they can refuse to edit a file the model never opened in this
      # turn. Nil-tolerant: tools that don't care just ignore it.
      attr_accessor :read_tracker

      # Optional Proc, injected by ToolExecutor, that the tool can call with
      # incremental output chunks during a long-running call. ShellTool uses
      # this to stream stdout/stderr lines as the subprocess writes them
      # instead of dumping everything at end-of-command. Nil-tolerant: a
      # tool with no streamable output (read, edit, glob) just ignores it.
      attr_accessor :stream_chunk

      # Convenience guard so tools don't sprinkle nil-checks at every emit.
      def emit_chunk(text)
        return if text.nil? || text.to_s.empty?

        @stream_chunk&.call(text.to_s)
      end

      # True when the user has requested cancellation. Cheap, lock-protected.
      # Use in tight loops; on true, terminate gracefully and either return
      # an "interrupted" string or raise Rubino::Interrupted.
      def cancellation_requested?
        @cancel_token&.cancelled?
      end

      # Returns the tool name (used in LLM tool definitions)
      def name
        raise NotImplementedError, "#{self.class}#name not implemented"
      end

      # The `tools.<key>` config gate that enables/disables this tool. Single
      # source of truth shared with Registry#tool_enabled_in_config? and the
      # `tools` CLI command, so the displayed state always matches the state
      # the registry actually enforces. Defaults to the tool's own name;
      # tools whose config key differs (webfetch/websearch both gate on
      # `tools.web`) override this. Returning a key absent from config means
      # the tool is enabled (opt-out model).
      def config_key
        name
      end

      # Returns a description for the LLM
      def description
        raise NotImplementedError, "#{self.class}#description not implemented"
      end

      # Returns the JSON schema for input parameters
      def input_schema
        raise NotImplementedError, "#{self.class}#input_schema not implemented"
      end

      # Returns the risk level: :low, :medium, :high
      def risk_level
        :low
      end

      # Executes the tool with given arguments, returns output string
      def call(arguments)
        raise NotImplementedError, "#{self.class}#call not implemented"
      end

      # Returns true if this tool requires user confirmation
      def risky?
        %i[medium high].include?(risk_level)
      end

      # Returns the tool definition for LLM registration
      def to_tool_definition
        {
          name: name,
          description: description,
          parameters: input_schema
        }
      end

      protected

      # Filesystem sandbox for write/edit/delete operations.
      #
      # Defaults to Dir.pwd, overridable via terminal.cwd in config. Mutating
      # tools must call within_workspace? before touching the disk so a prompt
      # injection that asks for `file_path: "/etc/passwd"` is refused at the
      # tool boundary, before the approval prompt even sees the path.
      #
      # The check resolves every symlink with File.realpath before comparing
      # against the workspace root: dropping a `link → /etc` inside the
      # workspace and writing through it used to bypass the boundary because
      # expand_path alone never crosses the symlink. realpath walks the
      # filesystem and gives us the canonical destination, so an in-workspace
      # path that ultimately points outside is rejected like any other escape.
      # For non-existent targets (write-creates-new-file) we resolve the
      # deepest existing ancestor and re-attach the remainder — the new file
      # will land at that ancestor, so the ancestor is what we sandbox.
      #
      # Set tools.workspace_strict=false in config.yml to disable globally
      # (the agent then trusts the model + the approval flow alone).
      # The directory tools sandbox to. Exposed as a class method so the
      # File API operations can root their Workspace at the SAME place
      # (otherwise produced artifacts under this root look like traversal
      # escapes relative to paths_home and the download 422s).
      # The PRIMARY root — terminal.cwd or the launch cwd. Kept as the single
      # source of truth for "the" directory: the @-picker, shell/test cwd, the
      # File API workspace and the attachment downloader all root here so they
      # agree. The write/edit SANDBOX, however, spans every root (see
      # #within_workspace?) so an added dir is also writable.
      def self.workspace_root
        Workspace.primary_root
      end

      # Every allowed root (primary + any --add-dir / /add-dir dirs). The
      # sandbox accepts a target under ANY of these.
      def self.workspace_roots
        Workspace.roots
      end

      def workspace_root
        self.class.workspace_root
      end

      def workspace_roots
        self.class.workspace_roots
      end

      def workspace_strict?
        Rubino.configuration.dig("tools", "workspace_strict") != false
      end

      # True when +expanded+ resolves under ANY allowed root. Generalised from
      # the old single-root check so a write/edit/multi_edit under a dir added
      # via --add-dir / /add-dir is accepted, while a path outside every root
      # is still refused. Symlinks are resolved (canonical_path) before the
      # comparison so an in-workspace symlink to /etc can't escape.
      def within_workspace?(expanded)
        return true unless workspace_strict?

        target_real = canonical_path(expanded)
        return false unless target_real

        Workspace.canonical_roots.any? do |root_real|
          target_real == root_real ||
            target_real.start_with?("#{root_real}#{File::SEPARATOR}")
        end
      end

      # Resolves `path` through every symlink to its canonical destination.
      # When the path doesn't exist yet (create-new-file flow) walks up to
      # the deepest existing ancestor, realpaths that, then re-joins the
      # missing tail. The tail itself can't traverse — expand_path already
      # collapsed `..` segments before we got here.
      def canonical_path(path)
        return nil if path.nil? || path.to_s.empty?

        expanded = File.expand_path(path.to_s)
        return File.realpath(expanded) if File.exist?(expanded)

        ancestor = expanded
        tail     = []
        until File.exist?(ancestor)
          parent = File.dirname(ancestor)
          break if parent == ancestor

          tail.unshift(File.basename(ancestor))
          ancestor = parent
        end
        return nil unless File.exist?(ancestor)

        File.join(File.realpath(ancestor), *tail)
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        nil
      end

      def workspace_violation_message(path)
        roots = workspace_roots
        where = roots.length == 1 ? roots.first : "any allowed root (#{roots.join(', ')})"
        "Error: refusing to access '#{path}' — outside #{where}. " \
          "Set tools.workspace_strict=false in config.yml to disable this check."
      end

      # Read-before-edit gate shared by EditTool and MultiEditTool. Refuses the
      # write when the model never read this file in the current turn, or read
      # it but the file changed on disk since. Returns nil (proceed) or an
      # error Hash carrying error_code: :stale_read for the model to recover
      # from. No tracker injected → no gate (single-tool unit tests, MCP calls).
      #
      # `verb` is the only token that varies between callers ("edit" /
      # "edits"); the wording is otherwise identical, so it lives here.
      def read_gate_error(expanded, display_path, verb:)
        return nil unless @read_tracker

        unless @read_tracker.seen?(expanded)
          return { output:     "Error: must use the read tool on #{display_path} in this turn before editing it. " \
                               "Read it first so the #{verb} can verify the surrounding context.",
                   error_code: :stale_read }
        end

        stashed = @read_tracker.mtime_at_read(expanded)
        current = File.mtime(expanded)
        return nil if stashed.nil? || current <= stashed

        { output:     "Error: #{display_path} changed on disk since the last read in this turn " \
                      "(read at #{stashed.utc.iso8601}, now #{current.utc.iso8601}). " \
                      "Re-read the file before editing so the #{verb} reflect the current contents.",
          error_code: :stale_read }
      end
    end
  end
end
